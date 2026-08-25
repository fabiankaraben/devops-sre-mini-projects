/*
 * ==============================================================================
 * Program: zombie_spawner.c
 * Description: Educational Linux process lifecycle simulator.
 *              Spawns controllable Zombie (defunct) and Orphan processes via
 *              POSIX fork(), exit(), sleep(), and signal handling.
 *
 * Part of: DevOps & SRE Mini-Projects
 * Domain:  01. Linux Scripting
 * ==============================================================================
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <signal.h>
#include <string.h>

#define COLOR_RESET   "\033[0m"
#define COLOR_GREEN   "\033[0;32m"
#define COLOR_YELLOW  "\033[0;33m"
#define COLOR_RED     "\033[0;31m"
#define COLOR_BLUE    "\033[0;34m"
#define COLOR_BOLD    "\033[1m"

static volatile sig_atomic_t g_reaped_count = 0;
static int g_handle_sigchld = 0;

void sigchld_handler(int sig) {
    (void)sig;
    pid_t pid;
    int status;
    // Reap all available dead children without blocking
    while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
        g_reaped_count++;
        printf("%s[SIGNAL] Caught SIGCHLD! Reaped zombie child PID %d%s\n", COLOR_GREEN, pid, COLOR_RESET);
    }
}

void print_usage(const char *prog_name) {
    printf("Usage: %s [OPTIONS]\n\n", prog_name);
    printf("Educational Zombie & Orphan Process Simulator (C Edition)\n\n");
    printf("Options:\n");
    printf("  -z, --zombies <N>        Spawn N zombie processes (parent sleeps without wait())\n");
    printf("  -o, --orphans <N>        Spawn N orphan processes (parent exits, children run)\n");
    printf("  -d, --duration <seconds> Seconds parent/orphans should sleep (default: 60)\n");
    printf("  -s, --handle-sigchld     Enable SIGCHLD handler to demonstrate gentle reaping\n");
    printf("  -h, --help               Display this help message and exit\n\n");
    printf("Examples:\n");
    printf("  %s --zombies 3 --duration 30\n", prog_name);
    printf("  %s --orphans 2 --duration 20\n", prog_name);
}

int main(int argc, char *argv[]) {
    int num_zombies = 0;
    int num_orphans = 0;
    int duration_sec = 60;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-z") == 0 || strcmp(argv[i], "--zombies") == 0) {
            if (i + 1 < argc) {
                num_zombies = atoi(argv[++i]);
            }
        } else if (strcmp(argv[i], "-o") == 0 || strcmp(argv[i], "--orphans") == 0) {
            if (i + 1 < argc) {
                num_orphans = atoi(argv[++i]);
            }
        } else if (strcmp(argv[i], "-d") == 0 || strcmp(argv[i], "--duration") == 0) {
            if (i + 1 < argc) {
                duration_sec = atoi(argv[++i]);
            }
        } else if (strcmp(argv[i], "-s") == 0 || strcmp(argv[i], "--handle-sigchld") == 0) {
            g_handle_sigchld = 1;
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            print_usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "Unknown argument: %s\n", argv[i]);
            print_usage(argv[0]);
            return 1;
        }
    }

    if (num_zombies == 0 && num_orphans == 0) {
        num_zombies = 2; // Default to 2 zombies
    }

    pid_t parent_pid = getpid();
    printf("\n%s%s======================================================%s\n", COLOR_BOLD, COLOR_BLUE, COLOR_RESET);
    printf("%s       Zombie & Orphan Simulator (PID: %d)%s\n", COLOR_BOLD, parent_pid, COLOR_RESET);
    printf("%s%s======================================================%s\n\n", COLOR_BOLD, COLOR_BLUE, COLOR_RESET);

    if (g_handle_sigchld) {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = sigchld_handler;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_RESTART | SA_NOCLDSTOP;
        sigaction(SIGCHLD, &sa, NULL);
        printf("%s[INFO] Installed SIGCHLD handler on parent PID %d.%s\n", COLOR_BLUE, parent_pid, COLOR_RESET);
    } else {
        printf("%s[INFO] Ignoring SIGCHLD (simulating a negligent parent).%s\n", COLOR_YELLOW, COLOR_RESET);
    }

    // 1. Spawn Zombies
    if (num_zombies > 0) {
        printf("%s[SPAWNER] Spawning %d zombie processes...%s\n", COLOR_YELLOW, num_zombies, COLOR_RESET);
        for (int i = 0; i < num_zombies; i++) {
            pid_t pid = fork();
            if (pid < 0) {
                perror("fork failed");
                exit(1);
            } else if (pid == 0) {
                // Child process exits immediately
                printf("  -> Child #%d (PID %d) exiting immediately to become a Zombie...\n", i + 1, getpid());
                exit(0);
            } else {
                // Parent does NOT call waitpid()
                printf("  -> Parent (PID %d) created child PID %d (unreaped)\n", parent_pid, pid);
            }
        }
    }

    // 2. Spawn Orphans
    if (num_orphans > 0) {
        printf("%s[SPAWNER] Spawning %d orphan processes...%s\n", COLOR_YELLOW, num_orphans, COLOR_RESET);
        for (int i = 0; i < num_orphans; i++) {
            pid_t pid = fork();
            if (pid < 0) {
                perror("fork failed");
                exit(1);
            } else if (pid == 0) {
                // Child sleeps in background, waiting for parent to die
                printf("  -> Orphan Child #%d (PID %d) running. Parent PID is %d\n", i + 1, getpid(), getppid());
                sleep(1); // Give parent time to exit
                printf("  -> Orphan Child #%d (PID %d) re-parented to init (New PPID: %d)\n", i + 1, getpid(), getppid());
                sleep(duration_sec);
                printf("  -> Orphan Child #%d (PID %d) exiting gracefully.\n", i + 1, getpid());
                exit(0);
            }
        }

        // If only spawning orphans, parent exits immediately to orphan the children
        if (num_zombies == 0) {
            printf("%s[PARENT] Exiting parent PID %d to orphan all children.%s\n", COLOR_RED, parent_pid, COLOR_RESET);
            exit(0);
        }
    }

    printf("\n%s[PARENT] Parent PID %d sleeping for %d seconds. Check 'ps aux | grep Z'%s\n",
           COLOR_GREEN, parent_pid, duration_sec, COLOR_RESET);
    fflush(stdout);

    // Sleep in small increments to allow signal handler execution
    for (int s = 0; s < duration_sec; s++) {
        sleep(1);
    }

    printf("%s[PARENT] Parent PID %d exiting now.%s\n", COLOR_BLUE, parent_pid, COLOR_RESET);
    return 0;
}
