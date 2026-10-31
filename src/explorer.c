/*
 * explorer.c — Wallpaper Engine on Linux 文件打开转发器
 *
 * 问题背景
 * --------
 * Wallpaper Engine 的「在资源管理器中打开」按钮，内部实现是：
 *
 *     ShellExecuteExW("explorer.exe", "/n,/select,<path>")
 *
 * 在 Wine/Proton 下，这会启动 Wine 自带的 explorer.exe，它只会打开一个
 * 简陋的 Wine 内部窗口，**不会转发到 Linux 主机的文件管理器**。结果就是：
 *
 *   - 点击「打开文件夹」没有任何可见反应（或者弹出一个空白 Wine 窗口）
 *   - 双击视频文件也不会调用主机的播放器
 *
 * 而且 Wallpaper Engine 调用时带了 SEE_MASK_FLAG_NO_UI，把错误提示抑制了，
 * 所以用户看到的只是「点了没反应」，没有任何报错。
 *
 * 解决方案
 * --------
 * 用一个自己编译的 explorer.exe 替换掉 prefix 里的原版。它接收同样的
 * "/n,/select,<path>" 参数，解析出真实路径后交给 winebrowser.exe，
 * 由 winebrowser 通过 xdg-open 转发到 Linux 主机的默认程序。
 *
 * 编译
 * ----
 *     x86_64-w64-mingw32-gcc -O2 -o explorer.exe explorer.c
 *
 * 部署
 * ----
 *     PREFIX/drive_c/windows/system32/explorer.exe
 *     PREFIX/drive_c/windows/explorer.exe
 *
 * 注意：先备份原文件（它是指向 Proton 目录的符号链接）：
 *     cp -P explorer.exe explorer.exe.wine-orig
 *
 * 日志
 * ----
 * 转发器会把每次调用记录到 C:\explorer-fwd.log（即 prefix/drive_c/explorer-fwd.log），
 * 便于排查。确认工作正常后可以注释掉 logline() 调用。
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdarg.h>

/* 写入调试日志到 C:\explorer-fwd.log */
static void logline(const char *fmt, ...)
{
    FILE *f = fopen("C:\\explorer-fwd.log", "a");
    if (!f) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fclose(f);
}

/* 去掉首尾的空白、换行和引号 */
static void trim(char *s)
{
    size_t n = strlen(s);
    while (n && (s[n - 1] == '\n' || s[n - 1] == '\r' ||
                 s[n - 1] == ' '  || s[n - 1] == '"'))
        s[--n] = 0;

    char *p = s;
    while (*p == '"') p++;
    if (p != s) memmove(s, p, strlen(p) + 1);
}

int main(int argc, char **argv)
{
    char target[MAX_PATH * 2] = {0};

    logline("[fwd] start argc=%d\n", argc);

    for (int i = 1; i < argc; i++) {
        char buf[MAX_PATH * 3];
        strncpy(buf, argv[i], sizeof(buf) - 1);
        buf[sizeof(buf) - 1] = 0;
        logline("[fwd] arg[%d]=%s\n", i, buf);

        /*
         * 关键点：Wallpaper Engine 把整个 "/n,/select,<path>" 作为**一个**
         * 参数传进来，而不是拆成多个。所以要在整串里搜索前缀。
         */
        char *p   = buf;
        char *hit = NULL;

        if      ((hit = strstr(p, "/select,"))) p = hit + 8;
        else if ((hit = strstr(p, "/open,")))   p = hit + 6;
        else if ((hit = strstr(p, "/e,")))      p = hit + 3;
        else if (p[0] == '/' && strchr(p, ',') == NULL) continue; /* 纯开关，如 /n */

        trim(p);
        if (*p) {
            strncpy(target, p, sizeof(target) - 1);
            trim(target);
        }
    }

    logline("[fwd] target=%s\n", target[0] ? target : "(empty)");

    if (!target[0]) {
        logline("[fwd] no target, exit\n");
        return 1;
    }

    /*
     * 交给 winebrowser：它会把 Windows 路径转换成主机可用的形式，
     * 再通过 xdg-open 用你的默认程序打开（文件管理器 / 视频播放器 / 看图工具）。
     */
    char cmd[MAX_PATH * 5];
    snprintf(cmd, sizeof(cmd),
             "\"C:\\windows\\system32\\winebrowser.exe\" \"%s\"", target);
    logline("[fwd] cmd=%s\n", cmd);

    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    BOOL ok = CreateProcessA(NULL, cmd, NULL, NULL, FALSE,
                             CREATE_NEW_PROCESS_GROUP, NULL, NULL, &si, &pi);
    logline("[fwd] CreateProcess=%d err=%lu\n", ok, ok ? 0 : GetLastError());

    if (ok) {
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
    }
    return ok ? 0 : 1;
}
