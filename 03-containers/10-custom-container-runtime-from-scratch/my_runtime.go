//go:build linux

package main

import (
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// ANSI Colors for formatted educational output
const (
	clrReset = "\033[0m"
	clrBold  = "\033[1m"
	clrGreen = "\033[1;32m"
	clrRed   = "\033[1;31m"
	clrYel   = "\033[1;33m"
	clrCyan  = "\033[1;36m"
	clrGray  = "\033[0;90m"
)

func printUsage() {
	fmt.Println(clrCyan + clrBold + "======================================================================" + clrReset)
	fmt.Println(clrCyan + clrBold + "  📦 Custom Container Runtime from Scratch (Pure Go & Linux Syscalls)" + clrReset)
	fmt.Println(clrCyan + clrBold + "======================================================================" + clrReset)
	fmt.Println("Usage: my_runtime <command> [options] [args...]")
	fmt.Println("\nCommands:")
	fmt.Println("  run   [options] <cmd> [args...]   Launch a new isolated container")
	fmt.Println("  info                              Display host namespace & cgroup capabilities")
	fmt.Println("\nRun Options:")
	fmt.Println("  --hostname <name>     Set container UTS hostname (default: box-container)")
	fmt.Println("  --rootfs   <path>     Path to Alpine/Linux rootfs bundle (default: /rootfs)")
	fmt.Println("  --mem      <limit>    Set Cgroup memory constraint (e.g., 64M, 128M)")
	fmt.Println("\nExample:")
	fmt.Println("  my_runtime run --hostname mybox --rootfs /rootfs --mem 64M /bin/sh")
	fmt.Println(clrCyan + "======================================================================" + clrReset)
}

func parseMemoryBytes(memStr string) (int64, error) {
	memStr = strings.TrimSpace(strings.ToUpper(memStr))
	if memStr == "" {
		return 0, nil
	}
	unit := int64(1)
	if strings.HasSuffix(memStr, "K") || strings.HasSuffix(memStr, "KB") {
		unit = 1024
		memStr = strings.TrimRight(memStr, "KB")
	} else if strings.HasSuffix(memStr, "M") || strings.HasSuffix(memStr, "MB") {
		unit = 1024 * 1024
		memStr = strings.TrimRight(memStr, "MB")
	} else if strings.HasSuffix(memStr, "G") || strings.HasSuffix(memStr, "GB") {
		unit = 1024 * 1024 * 1024
		memStr = strings.TrimRight(memStr, "GB")
	}

	val, err := strconv.ParseInt(memStr, 10, 64)
	if err != nil {
		return 0, err
	}
	return val * unit, nil
}

func setupCgroups(pid int, memLimitStr string) (func(), error) {
	if memLimitStr == "" {
		return func() {}, nil
	}

	bytes, err := parseMemoryBytes(memLimitStr)
	if err != nil {
		return func() {}, fmt.Errorf("invalid memory format: %w", err)
	}

	// Detect Cgroups v2 vs v1
	cgroupV2Path := "/sys/fs/cgroup"
	isCgroupV2 := false
	if _, err := os.Stat(filepath.Join(cgroupV2Path, "cgroup.controllers")); err == nil {
		isCgroupV2 = true
	}

	var cgroupDir string
	var cleanup func()

	if isCgroupV2 {
		cgroupDir = filepath.Join(cgroupV2Path, fmt.Sprintf("my_runtime_%d", pid))
		if err := os.MkdirAll(cgroupDir, 0755); err != nil {
			return func() {}, fmt.Errorf("cgroups v2 mkdir failed: %w", err)
		}

		// Write memory.max
		maxFile := filepath.Join(cgroupDir, "memory.max")
		_ = os.WriteFile(maxFile, []byte(strconv.FormatInt(bytes, 10)), 0644)

		// Add process to cgroup.procs
		procsFile := filepath.Join(cgroupDir, "cgroup.procs")
		_ = os.WriteFile(procsFile, []byte(strconv.Itoa(pid)), 0644)

		cleanup = func() {
			os.RemoveAll(cgroupDir)
		}
	} else {
		// Cgroups v1 fallback
		cgroupV1Mem := "/sys/fs/cgroup/memory"
		cgroupDir = filepath.Join(cgroupV1Mem, fmt.Sprintf("my_runtime_%d", pid))
		if err := os.MkdirAll(cgroupDir, 0755); err != nil {
			return func() {}, fmt.Errorf("cgroups v1 mkdir failed: %w", err)
		}

		limitFile := filepath.Join(cgroupDir, "memory.limit_in_bytes")
		_ = os.WriteFile(limitFile, []byte(strconv.FormatInt(bytes, 10)), 0644)

		tasksFile := filepath.Join(cgroupDir, "tasks")
		_ = os.WriteFile(tasksFile, []byte(strconv.Itoa(pid)), 0644)

		cleanup = func() {
			os.RemoveAll(cgroupDir)
		}
	}

	return cleanup, nil
}

func runParent() {
	// Parse runtime flags
	args := os.Args[2:]
	hostname := "box-container"
	rootfs := "/rootfs"
	memLimit := ""
	var targetCmd string
	var targetArgs []string

	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "--hostname" && i+1 < len(args) {
			hostname = args[i+1]
			i += 2
		} else if arg == "--rootfs" && i+1 < len(args) {
			rootfs = args[i+1]
			i += 2
		} else if arg == "--mem" && i+1 < len(args) {
			memLimit = args[i+1]
			i += 2
		} else if !strings.HasPrefix(arg, "--") {
			targetCmd = arg
			targetArgs = args[i+1:]
			break
		} else {
			i++
		}
	}

	if targetCmd == "" {
		targetCmd = "/bin/sh"
	}

	// Resolve absolute path for rootfs if local
	absRootfs, err := filepath.Abs(rootfs)
	if err == nil {
		rootfs = absRootfs
	}

	// Prepare child re-execution arguments
	childArgs := []string{
		"child",
		"--hostname", hostname,
		"--rootfs", rootfs,
		targetCmd,
	}
	childArgs = append(childArgs, targetArgs...)

	// Re-execute itself via /proc/self/exe with new Linux kernel namespaces
	cmd := exec.Command("/proc/self/exe", childArgs...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	// Configure CLONE namespaces: UTS (hostname), PID (processes), NS (mounts), IPC (shared memory)
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags: syscall.CLONE_NEWUTS |
			syscall.CLONE_NEWPID |
			syscall.CLONE_NEWNS |
			syscall.CLONE_NEWIPC,
	}

	if err := cmd.Start(); err != nil {
		log.Fatalf(clrRed+"❌ Failed to spawn container process: %v"+clrReset, err)
	}

	// Apply Cgroups resource limits to the newly spawned PID
	cleanupCgroups, err := setupCgroups(cmd.Process.Pid, memLimit)
	if err != nil {
		fmt.Fprintf(os.Stderr, clrYel+"⚠️  Warning: Cgroups configuration notice: %v\n"+clrReset, err)
	}
	defer cleanupCgroups()

	if err := cmd.Wait(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			os.Exit(exitErr.ExitCode())
		}
		os.Exit(1)
	}
}

func runChild() {
	args := os.Args[2:]
	hostname := "box-container"
	rootfs := "/rootfs"
	var targetCmd string
	var targetArgs []string

	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "--hostname" && i+1 < len(args) {
			hostname = args[i+1]
			i += 2
		} else if arg == "--rootfs" && i+1 < len(args) {
			rootfs = args[i+1]
			i += 2
		} else if !strings.HasPrefix(arg, "--") {
			targetCmd = arg
			targetArgs = args[i+1:]
			break
		} else {
			i++
		}
	}

	if targetCmd == "" {
		targetCmd = "/bin/sh"
	}

	// 1. Configure UTS Namespace Hostname
	if err := syscall.Sethostname([]byte(hostname)); err != nil {
		log.Fatalf("Sethostname failed: %v", err)
	}

	// 2. Configure Mount Namespace: Make mounts private to prevent leakage to host
	if err := syscall.Mount("", "/", "", syscall.MS_PRIVATE|syscall.MS_REC, ""); err != nil {
		log.Fatalf("Mount MS_PRIVATE failed: %v", err)
	}

	// 3. Prepare Rootfs & Proc Virtual Filesystem
	if _, err := os.Stat(rootfs); os.IsNotExist(err) {
		log.Fatalf("Rootfs directory '%s' does not exist", rootfs)
	}

	procDir := filepath.Join(rootfs, "proc")
	os.MkdirAll(procDir, 0755)

	// Mount isolated /proc virtual filesystem so 'ps' inside sees only container processes (PID 1)
	if err := syscall.Mount("proc", procDir, "proc", 0, ""); err != nil {
		log.Fatalf("Mount /proc failed: %v", err)
	}

	// 4. Filesystem Isolation: Chroot into Rootfs Bundle
	if err := syscall.Chroot(rootfs); err != nil {
		log.Fatalf("Chroot into '%s' failed: %v", rootfs, err)
	}

	if err := os.Chdir("/"); err != nil {
		log.Fatalf("Chdir / failed: %v", err)
	}

	// 5. Execute User Target Process as PID 1
	cmd := exec.Command(targetCmd, targetArgs...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = []string{
		"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
		"TERM=xterm",
		"HOME=/root",
	}

	if err := cmd.Run(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			os.Exit(exitErr.ExitCode())
		}
		os.Exit(1)
	}
}

func printInfo() {
	fmt.Println(clrCyan + clrBold + "======================================================================" + clrReset)
	fmt.Println(clrCyan + clrBold + "  ℹ️  Custom Container Runtime - Host Environment Inspection" + clrReset)
	fmt.Println(clrCyan + clrBold + "======================================================================" + clrReset)
	fmt.Printf("  • Hostname:       %s\n", os.Getenv("HOSTNAME"))
	fmt.Printf("  • Parent PID:     %d\n", os.Getpid())
	fmt.Printf("  • Current User:   UID %d / GID %d\n", os.Getuid(), os.Getgid())

	// Namespaces check
	nsDir := fmt.Sprintf("/proc/%d/ns", os.Getpid())
	if entries, err := os.ReadDir(nsDir); err == nil {
		fmt.Println("  • Active Namespaces:")
		for _, e := range entries {
			target, _ := os.Readlink(filepath.Join(nsDir, e.Name()))
			fmt.Printf("      - %-8s -> %s\n", e.Name(), target)
		}
	}

	// Cgroups check
	cgroupV2 := "/sys/fs/cgroup/cgroup.controllers"
	if _, err := os.Stat(cgroupV2); err == nil {
		controllers, _ := os.ReadFile(cgroupV2)
		fmt.Printf("  • Cgroups:        v2 (Controllers: %s)\n", strings.TrimSpace(string(controllers)))
	} else {
		fmt.Printf("  • Cgroups:        v1 (Legacy)\n")
	}
	fmt.Println(clrCyan + "======================================================================" + clrReset)
}

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(0)
	}

	switch os.Args[1] {
	case "run":
		runParent()
	case "child":
		runChild()
	case "info":
		printInfo()
	case "-h", "--help", "help":
		printUsage()
	default:
		fmt.Fprintf(os.Stderr, clrRed+"Unknown command: %s\n\n"+clrReset, os.Args[1])
		printUsage()
		os.Exit(1)
	}
}
