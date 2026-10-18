// fancurve: drive the Mac's fans from the hotter of the CPU and GPU sensor averages.
//
// Reads the SMC directly. Writing fan speeds needs root; whenever the program
// exits normally (Ctrl-C, SIGTERM, launchd stop) the fans go back to Auto.
// Settings come from a small key=value file that the menu-bar app edits, and
// the current state is written as JSON for the app to show.
#include <IOKit/IOKitLib.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define STATE_DIR "/Library/Application Support/fancurve"
#define MAX_SENSORS 512
#define MAX_FANS 8
#define HISTORY 100      // samples kept for the app's chart
#define HISTORY_EVERY 3  // ticks per sample: 3 x 2 s = 10 minutes of history

typedef struct { char major, minor, build, reserved; UInt16 release; } SMCVers;
typedef struct { UInt16 version, length; UInt32 cpu, gpu, mem; } SMCPLimit;
typedef struct { UInt32 size, type; char attributes; } SMCKeyInfo;
typedef struct {
  UInt32 key;
  SMCVers vers;
  SMCPLimit plimit;
  SMCKeyInfo info;
  char result, status, cmd;
  UInt32 data32;
  unsigned char bytes[32];
} SMCData;

enum { CMD_READ = 5, CMD_WRITE = 6, CMD_INDEX = 8, CMD_INFO = 9 };

typedef struct { char mode[8]; double low, high, hot; } Config;
typedef struct { double cpu, gpu, hot; char hot_key[5]; } Temps;

static io_connect_t conn;
static volatile sig_atomic_t stopping;

static UInt32 key_of(const char *s) {
  return (UInt32)s[0] << 24 | (UInt32)s[1] << 16 | (UInt32)s[2] << 8 | (UInt32)s[3];
}

static void name_of(UInt32 k, char out[5]) {
  out[0] = k >> 24; out[1] = k >> 16; out[2] = k >> 8; out[3] = k; out[4] = 0;
}

static int smc(SMCData *in, SMCData *out) {
  size_t n = sizeof *out;
  if (IOConnectCallStructMethod(conn, 2, in, sizeof *in, out, &n) != kIOReturnSuccess) return -1;
  return out->result ? -1 : 0;
}

static int smc_info(UInt32 key, SMCKeyInfo *info) {
  SMCData in = {0}, out = {0};
  in.key = key;
  in.cmd = CMD_INFO;
  if (smc(&in, &out)) return -1;
  *info = out.info;
  return 0;
}

static int smc_read(UInt32 key, SMCKeyInfo *info, unsigned char *bytes) {
  if (smc_info(key, info)) return -1;
  SMCData in = {0}, out = {0};
  in.key = key;
  in.cmd = CMD_READ;
  in.info.size = info->size;
  if (smc(&in, &out)) return -1;
  memcpy(bytes, out.bytes, 32);
  return 0;
}

static int smc_write(const char *name, const void *val, UInt32 size) {
  SMCKeyInfo info;
  if (smc_info(key_of(name), &info) || info.size != size) return -1;
  SMCData in = {0}, out = {0};
  in.key = key_of(name);
  in.cmd = CMD_WRITE;
  in.info.size = size;
  memcpy(in.bytes, val, size);
  return smc(&in, &out);
}

static int read_flt(UInt32 key, float *v) {
  SMCKeyInfo info;
  unsigned char b[32];
  if (smc_read(key, &info, b) || info.type != key_of("flt ")) return -1;
  memcpy(v, b, 4);
  return 0;
}

static int read_u8(const char *name, int *v) {
  SMCKeyInfo info;
  unsigned char b[32];
  if (smc_read(key_of(name), &info, b) || info.type != key_of("ui8 ")) return -1;
  *v = b[0];
  return 0;
}

static void fan_key(char out[5], int fan, const char *suffix) { snprintf(out, 5, "F%d%s", fan, suffix); }

// Sensors. Apple does not document the keys; like macmon, Tp* are taken as
// CPU and Tg* as GPU. Other T* keys include limits and odd values, so they
// are ignored.
static UInt32 cpu_keys[MAX_SENSORS], gpu_keys[MAX_SENSORS];
static int n_cpu, n_gpu;

static void find_sensors(void) {
  SMCKeyInfo info;
  unsigned char b[32];
  if (smc_read(key_of("#KEY"), &info, b)) return;
  UInt32 n = (UInt32)b[0] << 24 | (UInt32)b[1] << 16 | (UInt32)b[2] << 8 | b[3];
  for (UInt32 i = 0; i < n; i++) {
    SMCData in = {0}, out = {0};
    in.cmd = CMD_INDEX;
    in.data32 = i;
    if (smc(&in, &out)) continue;
    char name[5];
    float v;
    name_of(out.key, name);
    if (name[0] != 'T' || (name[1] != 'p' && name[1] != 'g') || read_flt(out.key, &v)) continue;
    if (name[1] == 'p' && n_cpu < MAX_SENSORS) cpu_keys[n_cpu++] = out.key;
    if (name[1] == 'g' && n_gpu < MAX_SENSORS) gpu_keys[n_gpu++] = out.key;
  }
}

typedef struct { double avg, hot; char hot_key[5]; int stale; } Group;
static Group cpu_group = {NAN, -1, "-", 0}, gpu_group = {NAN, -1, "-", 0};

// While the CPU idles, a block of its sensors often returns placeholder values
// (0, ±4, 40.0) for a moment; averaged in, they gave readings like 31.7 °C.
// A reading is used only when at least 90% of the sensors give a plausible
// temperature. Otherwise the previous reading stands in, for up to 5 ticks.
static void read_group(const UInt32 *keys, int n, Group *g) {
  double sum = 0, hot = -1;
  char hot_key[5] = "-";
  int k = 0;
  for (int i = 0; i < n; i++) {
    float v;
    if (read_flt(keys[i], &v) || v < 15 || v > 150) continue;
    sum += v;
    k++;
    if (v > hot) { hot = v; name_of(keys[i], hot_key); }
  }
  if (n > 0 && k >= 0.9 * n) {
    g->avg = sum / k;
    g->hot = hot;
    strcpy(g->hot_key, hot_key);
    g->stale = 0;
  } else if (++g->stale > 5) {
    g->avg = NAN;
    g->hot = -1;
    strcpy(g->hot_key, "-");
  }
}

static int read_temps(Temps *t) {
  read_group(cpu_keys, n_cpu, &cpu_group);
  read_group(gpu_keys, n_gpu, &gpu_group);
  t->cpu = cpu_group.avg;
  t->gpu = gpu_group.avg;
  const Group *h = cpu_group.hot >= gpu_group.hot ? &cpu_group : &gpu_group;
  t->hot = h->hot;
  strcpy(t->hot_key, h->hot_key);
  return isnan(t->cpu) && isnan(t->gpu) ? -1 : 0;
}

// Fans.
static int n_fans;
static float fan_min[MAX_FANS], fan_max[MAX_FANS];
static char mode_key[MAX_FANS][5];

// Fanless Macs (MacBook Air) report no fans; the service then only records temperatures.
static int find_fans(void) {
  int n;
  if (read_u8("FNum", &n) || n < 1) {
    n_fans = 0;
    return 0;
  }
  n_fans = n > MAX_FANS ? MAX_FANS : n;
  for (int i = 0; i < n_fans; i++) {
    char k[5];
    fan_key(k, i, "Mn");
    if (read_flt(key_of(k), &fan_min[i])) return -1;
    fan_key(k, i, "Mx");
    if (read_flt(key_of(k), &fan_max[i])) return -1;
    SMCKeyInfo info;
    fan_key(mode_key[i], i, "md");
    if (smc_info(key_of(mode_key[i]), &info)) fan_key(mode_key[i], i, "Md");
  }
  return 0;
}

static int set_auto(void) {
  unsigned char zero = 0;
  int bad = 0;
  for (int i = 0; i < n_fans; i++)
    if (smc_write(mode_key[i], &zero, 1)) bad = 1;
  return bad ? -1 : 0;
}

// Settings. Values are clamped so a bad file cannot leave the Mac uncooled.
static double clamp(double v, double lo, double hi) { return v < lo ? lo : v > hi ? hi : v; }

static void config_load(const char *path, Config *c) {
  FILE *f = fopen(path, "r");
  if (!f) return;
  Config n = *c;
  char line[128], key[32], val[32];
  while (fgets(line, sizeof line, f)) {
    if (sscanf(line, " %31[a-z] = %31s", key, val) != 2) continue;
    if (!strcmp(key, "mode") && (!strcmp(val, "curve") || !strcmp(val, "max") || !strcmp(val, "auto")))
      strcpy(n.mode, val);
    else if (!strcmp(key, "low")) n.low = atof(val);
    else if (!strcmp(key, "high")) n.high = atof(val);
    else if (!strcmp(key, "hot")) n.hot = atof(val);
  }
  fclose(f);
  n.low = clamp(n.low, 30, 90);
  n.high = clamp(n.high, n.low + 5, 100);
  n.hot = clamp(n.hot, 90, 110);
  *c = n;
}

static time_t mtime_of(const char *path) {
  struct stat st;
  return stat(path, &st) ? 0 : st.st_mtime;
}

// State file for the app. Written to a temp file and renamed into place.
static struct { time_t t; double cpu, gpu; } hist[HISTORY];
static int hist_n, hist_pos;

static void json_num(FILE *f, double v, const char *fmt) {
  if (isnan(v)) fputs("null", f);
  else fprintf(f, fmt, v);
}

static void write_state(const char *path, const Config *c, const Temps *t, const float *actual,
                        const float *target, int dry, int controlling, int conflict) {
  char tmp[1100];
  snprintf(tmp, sizeof tmp, "%s.tmp", path);
  FILE *f = fopen(tmp, "w");
  if (!f) return;
  fprintf(f, "{\"time\":%ld,\"mode\":\"%s\",\"low\":%.1f,\"high\":%.1f,\"hot\":%.1f,", (long)time(NULL),
          c->mode, c->low, c->high, c->hot);
  fprintf(f, "\"dry\":%s,\"controlling\":%s,\"conflict\":%s,\"cpu\":", dry ? "true" : "false",
          controlling ? "true" : "false", conflict ? "true" : "false");
  json_num(f, t->cpu, "%.1f");
  fputs(",\"gpu\":", f);
  json_num(f, t->gpu, "%.1f");
  fprintf(f, ",\"hottest\":%.1f,\"hottestKey\":\"%s\",\"fans\":[", t->hot, t->hot_key);
  for (int i = 0; i < n_fans; i++) {
    fprintf(f, "%s{\"actual\":", i ? "," : "");
    json_num(f, actual[i], "%.0f");
    fputs(",\"target\":", f);
    json_num(f, target[i], "%.0f");
    fprintf(f, ",\"min\":%.0f,\"max\":%.0f}", fan_min[i], fan_max[i]);
  }
  fputs("],\"history\":[", f);
  for (int i = 0; i < hist_n; i++) {
    int j = (hist_pos - hist_n + i + HISTORY) % HISTORY;
    fprintf(f, "%s[%ld,", i ? "," : "", (long)hist[j].t);
    json_num(f, hist[j].cpu, "%.1f");
    fputc(',', f);
    json_num(f, hist[j].gpu, "%.1f");
    fputc(']', f);
  }
  fputs("]}\n", f);
  if (fclose(f) == 0) rename(tmp, path);
}

static void stamp(void) {
  char b[32];
  time_t now = time(NULL);
  strftime(b, sizeof b, "%m-%d %H:%M:%S", localtime(&now));
  printf("%s  ", b);
}

static void on_signal(int sig) {
  (void)sig;
  stopping = 1;
}

static void nap(double seconds) {
  struct timespec ts = {(time_t)seconds, (long)((seconds - floor(seconds)) * 1e9)};
  nanosleep(&ts, NULL);
}

static double curve_frac(const Config *c, double temp) {
  return clamp((temp - c->low) / (c->high - c->low), 0, 1);
}

static void usage(void) {
  puts("usage: fancurve [--status | --auto | --dry-run] [--interval S] [--log-every S]\n"
       "                [--config FILE] [--state FILE]");
}

int main(int argc, char **argv) {
  int dry = 0, status = 0, auto_only = 0, log_every = 10;
  double interval = 2;
  const char *config_path = STATE_DIR "/config", *state_path = STATE_DIR "/status.json";
  for (int i = 1; i < argc; i++) {
    const char *a = argv[i], *next = i + 1 < argc ? argv[i + 1] : NULL;
    if (!strcmp(a, "--dry-run")) dry = 1;
    else if (!strcmp(a, "--status")) status = 1;
    else if (!strcmp(a, "--auto")) auto_only = 1;
    else if (!strcmp(a, "--interval") && next) interval = clamp(atof(argv[++i]), 0.5, 30);
    else if (!strcmp(a, "--log-every") && next) log_every = atoi(argv[++i]);
    else if (!strcmp(a, "--config") && next) config_path = argv[++i];
    else if (!strcmp(a, "--state") && next) state_path = argv[++i];
    else { usage(); return 2; }
  }
  setvbuf(stdout, NULL, _IOLBF, 0);

  io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
  if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &conn) != kIOReturnSuccess) {
    puts("AppleSMC를 열지 못했습니다.");
    return 1;
  }
  if (find_fans()) {
    puts("팬 정보를 읽지 못했습니다.");
    return 1;
  }
  if ((auto_only || !(dry || status)) && geteuid() != 0) {
    puts("팬 속도를 바꾸려면 sudo가 필요합니다.");
    return 1;
  }
  if (auto_only) {
    if (set_auto()) { puts("팬을 Auto로 되돌리지 못했습니다."); return 1; }
    puts("팬을 Auto로 되돌렸습니다.");
    return 0;
  }
  find_sensors();

  Config cfg = {"curve", 50, 80, 105};
  config_load(config_path, &cfg);
  time_t cfg_mtime = mtime_of(config_path);

  if (status) {
    Temps t;
    // The first read can land on a placeholder moment; try a few times.
    int bad = read_temps(&t);
    for (int i = 0; i < 10 && (bad || isnan(t.cpu) || isnan(t.gpu)); i++) {
      nap(0.1);
      bad = read_temps(&t);
    }
    if (bad) { puts("온도를 읽지 못했습니다."); return 1; }
    printf("온도: CPU 평균 %.1f°C (센서 %d개), GPU 평균 %.1f°C (센서 %d개), 가장 뜨거운 센서 %.1f°C (%s)\n",
           t.cpu, n_cpu, t.gpu, n_gpu, t.hot, t.hot_key);
    for (int i = 0; i < n_fans; i++) {
      char k[5];
      float ac = NAN, tg = NAN;
      int md = -1;
      fan_key(k, i, "Ac");
      read_flt(key_of(k), &ac);
      fan_key(k, i, "Tg");
      read_flt(key_of(k), &tg);
      read_u8(mode_key[i], &md);
      printf("팬 %d: 실제 %.0f rpm, 목표 %.0f rpm, 범위 %.0f-%.0f, 모드 %s\n", i + 1, ac, tg, fan_min[i], fan_max[i],
             md == 1 ? "수동" : md == 0 ? "자동" : "?");
    }
    double frac = !strcmp(cfg.mode, "max") || t.hot >= cfg.hot ? 1 : curve_frac(&cfg, fmax(t.cpu, t.gpu));
    printf("설정: %s, %.0f°C부터 올려서 %.0f°C에 최대, 센서 하나라도 %.0f°C 이상이면 최대\n",
           !strcmp(cfg.mode, "curve") ? "곡선" : !strcmp(cfg.mode, "max") ? "최대" : "Apple 자동", cfg.low, cfg.high,
           cfg.hot);
    if (!n_fans) puts("이 Mac에는 팬이 없습니다. 온도만 기록합니다.");
    else if (strcmp(cfg.mode, "auto"))
      printf("지금 이 설정이면: %.0f rpm\n", fan_min[0] + frac * (fan_max[0] - fan_min[0]));
    return 0;
  }

  struct sigaction sa = {0};
  sa.sa_handler = on_signal;
  sigaction(SIGINT, &sa, NULL);
  sigaction(SIGTERM, &sa, NULL);
  sigaction(SIGHUP, &sa, NULL);
  signal(SIGPIPE, SIG_IGN);

  stamp();
  printf("시작%s: 팬 %d개, CPU 센서 %d개, GPU 센서 %d개, 설정 %s %.0f→%.0f°C (최고 %.0f°C)\n",
         dry ? " (시험 모드, 팬은 건드리지 않음)" : "", n_fans, n_cpu, n_gpu, cfg.mode, cfg.low, cfg.high, cfg.hot);

  double ema = NAN, frac_cmd = 0;
  float last[MAX_FANS], actual[MAX_FANS], target[MAX_FANS];
  for (int i = 0; i < MAX_FANS; i++) last[i] = -1;
  int fails = 0, conflict_ticks = 0, was_hot = 0, was_auto = 0, rc = 0;
  int log_ticks = log_every > 0 ? (int)fmax(1, log_every / interval) : 0;

  for (long tick = 0; !stopping; tick++) {
    time_t m = mtime_of(config_path);
    if (m != cfg_mtime) {
      cfg_mtime = m;
      config_load(config_path, &cfg);
      stamp();
      printf("설정 변경: %s %.0f→%.0f°C (최고 %.0f°C)\n", cfg.mode, cfg.low, cfg.high, cfg.hot);
    }

    Temps t;
    if (read_temps(&t)) {
      if (++fails >= 3) {
        stamp();
        puts("온도를 읽지 못했습니다. 팬을 Auto로 되돌리고 끝냅니다.");
        rc = 1;
        break;
      }
      nap(interval);
      continue;
    }
    fails = 0;

    double hotter = fmax(t.cpu, t.gpu);
    ema = isnan(ema) ? hotter : ema + 0.3 * (hotter - ema);
    int is_auto = !strcmp(cfg.mode, "auto");
    int is_hot = !is_auto && t.hot >= cfg.hot;
    double frac = !strcmp(cfg.mode, "max") || is_hot ? 1 : curve_frac(&cfg, ema);
    // Speed up at once, slow down gently (full range in about 100 s).
    frac_cmd = frac >= frac_cmd ? frac : fmax(frac, frac_cmd - 0.01 * interval);

    int conflict = 0, write_failed = 0;
    for (int i = 0; i < n_fans; i++) {
      char k[5];
      fan_key(k, i, "Ac");
      if (read_flt(key_of(k), &actual[i])) actual[i] = NAN;
      target[i] = is_auto ? NAN : fan_min[i] + frac_cmd * (fan_max[i] - fan_min[i]);
      if (dry || is_auto) continue;
      float tg;
      int md;
      fan_key(k, i, "Tg");
      if (last[i] >= 0 && !read_flt(key_of(k), &tg) && fabsf(tg - last[i]) > 100) conflict = 1;
      int manual = !read_u8(mode_key[i], &md) && md == 1;
      if (manual && fabsf(target[i] - last[i]) < 30 && tick % 15 && !conflict) continue;
      unsigned char one = 1;
      if ((!manual && smc_write(mode_key[i], &one, 1)) || smc_write(k, &target[i], 4)) {
        write_failed = 1;
        break;
      }
      last[i] = target[i];
    }
    if (write_failed) {
      stamp();
      puts("팬 속도를 쓰지 못했습니다. 팬을 Auto로 되돌리고 끝냅니다.");
      rc = 1;
      break;
    }

    if (is_auto != was_auto) {
      if (is_auto && !dry) set_auto();
      for (int i = 0; i < n_fans; i++) last[i] = -1;
      was_auto = is_auto;
    }
    conflict_ticks = conflict ? conflict_ticks + 1 : 0;
    if (conflict_ticks == 3) {
      stamp();
      puts("다른 프로그램이 팬 속도를 바꾸고 있습니다. Macs Fan Control을 Auto로 두거나 종료하세요.");
    }
    if (is_hot != was_hot) {
      stamp();
      printf(is_hot ? "센서 %.1f°C (%s): 팬 최대\n" : "센서 %.1f°C (%s): 곡선으로 복귀\n", t.hot, t.hot_key);
      was_hot = is_hot;
    }
    if (tick % HISTORY_EVERY == 0) {
      hist[hist_pos].t = time(NULL);
      hist[hist_pos].cpu = t.cpu;
      hist[hist_pos].gpu = t.gpu;
      hist_pos = (hist_pos + 1) % HISTORY;
      if (hist_n < HISTORY) hist_n++;
    }
    write_state(state_path, &cfg, &t, actual, target, dry, !dry && !is_auto && n_fans, conflict_ticks >= 3);

    if (log_ticks && tick % log_ticks == 0) {
      stamp();
      printf("CPU %.1f°C  GPU %.1f°C  최고 %.1f°C", t.cpu, t.gpu, t.hot);
      if (!n_fans) printf("  (팬 없음)");
      else if (is_auto) printf("  → Apple 자동");
      else printf("  → %s%.0f rpm", dry ? "목표(시험) " : "목표 ", target[0]);
      for (int i = 0; i < n_fans; i++) printf(i ? " / %.0f" : "  [실제 %.0f", actual[i]);
      puts(n_fans ? " rpm]" : "");
    }
    nap(interval);
  }

  if (!dry) {
    stamp();
    puts(set_auto() ? "경고: 팬을 Auto로 되돌리지 못했습니다. sudo ./fan.sh auto 를 실행하세요."
                    : "팬을 Auto로 되돌렸습니다.");
  }
  return rc;
}
