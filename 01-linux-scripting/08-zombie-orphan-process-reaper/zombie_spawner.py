#!/usr/bin/env python3
"""
Zombie and Orphan Process Spawner (Python Edition)
==================================================
Simulates defective parent processes creating Zombie (defunct) and Orphan
processes for testing process monitoring and reaping engines.

Part of: DevOps & SRE Mini-Projects
Domain:  01. Linux Scripting
"""

import argparse
import os
import signal
import sys
import time

COLOR_RESET = "\033[0m"
COLOR_GREEN = "\033[0;32m"
COLOR_YELLOW = "\033[0;33m"
COLOR_RED = "\033[0;31m"
COLOR_BLUE = "\033[0;34m"
COLOR_BOLD = "\033[1m"


def sigchld_handler(signum, frame):
    """Reaps zombie child processes when SIGCHLD is caught."""
    del signum, frame
    while True:
        try:
            pid, status = os.waitpid(-1, os.WNOHANG)
            if pid <= 0:
                break
            print(f"{COLOR_GREEN}[SIGNAL] Caught SIGCHLD! Reaped zombie child PID {pid}{COLOR_RESET}")
        except ChildProcessError:
            break


def main():
    parser = argparse.ArgumentParser(
        description="Educational Zombie and Orphan Process Spawner (Python Edition)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "-z", "--zombies",
        type=int,
        default=0,
        help="Number of zombie processes to create (children exit, parent sleeps without wait())",
    )
    parser.add_argument(
        "-o", "--orphans",
        type=int,
        default=0,
        help="Number of orphan processes to create (parent exits, children loop in background)",
    )
    parser.add_argument(
        "-d", "--duration",
        type=int,
        default=60,
        help="Duration in seconds for parent/orphans to sleep (default: 60)",
    )
    parser.add_argument(
        "-s", "--handle-sigchld",
        action="store_true",
        help="Install SIGCHLD handler to demonstrate gentle reaping",
    )

    args = parser.parse_args()

    num_zombies = args.zombies
    num_orphans = args.orphans
    if num_zombies == 0 and num_orphans == 0:
        num_zombies = 2

    parent_pid = os.getpid()
    print(f"\n{COLOR_BOLD}{COLOR_BLUE}======================================================{COLOR_RESET}")
    print(f"{COLOR_BOLD}    Zombie & Orphan Simulator (Python PID: {parent_pid}){COLOR_RESET}")
    print(f"{COLOR_BOLD}{COLOR_BLUE}======================================================{COLOR_RESET}\n")

    if args.handle_sigchld:
        signal.signal(signal.SIGCHLD, sigchld_handler)
        print(f"{COLOR_BLUE}[INFO] Installed SIGCHLD signal handler on parent PID {parent_pid}.{COLOR_RESET}")
    else:
        print(f"{COLOR_YELLOW}[INFO] Ignoring SIGCHLD (simulating a negligent parent).{COLOR_RESET}")

    # 1. Spawn Zombies
    if num_zombies > 0:
        print(f"{COLOR_YELLOW}[SPAWNER] Spawning {num_zombies} zombie processes...{COLOR_RESET}")
        for i in range(num_zombies):
            pid = os.fork()
            if pid == 0:
                # Child process exits immediately
                print(f"  -> Child #{i+1} (PID {os.getpid()}) exiting immediately to become a Zombie...")
                os._exit(0)
            else:
                # Parent does not call waitpid
                print(f"  -> Parent (PID {parent_pid}) created child PID {pid} (unreaped)")

    # 2. Spawn Orphans
    if num_orphans > 0:
        print(f"{COLOR_YELLOW}[SPAWNER] Spawning {num_orphans} orphan processes...{COLOR_RESET}")
        for i in range(num_orphans):
            pid = os.fork()
            if pid == 0:
                # Child process
                print(f"  -> Orphan Child #{i+1} (PID {os.getpid()}) running. Parent PID: {os.getppid()}")
                time.sleep(1)
                print(f"  -> Orphan Child #{i+1} (PID {os.getpid()}) re-parented to init (New PPID: {os.getppid()})")
                time.sleep(args.duration)
                print(f"  -> Orphan Child #{i+1} (PID {os.getpid()}) exiting.")
                os._exit(0)

        # If only spawning orphans, exit parent immediately
        if num_zombies == 0:
            print(f"{COLOR_RED}[PARENT] Parent PID {parent_pid} exiting now to detach orphans.{COLOR_RESET}")
            sys.exit(0)

    print(f"\n{COLOR_GREEN}[PARENT] Parent PID {parent_pid} sleeping for {args.duration}s. Inspect with 'ps aux | grep Z'{COLOR_RESET}")
    sys.stdout.flush()

    for _ in range(args.duration):
        time.sleep(1)

    print(f"{COLOR_BLUE}[PARENT] Parent PID {parent_pid} exiting now.{COLOR_RESET}")


if __name__ == "__main__":
    main()
