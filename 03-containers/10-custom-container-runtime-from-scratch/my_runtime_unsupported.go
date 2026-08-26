//go:build !linux

package main

import (
	"fmt"
	"os"
	"runtime"
)

func main() {
	fmt.Fprintf(os.Stderr, "Error: my_runtime relies on Linux kernel namespaces (CLONE_NEW*) and Cgroups.\n")
	fmt.Fprintf(os.Stderr, "Host OS '%s/%s' is not supported natively.\n\n", runtime.GOOS, runtime.GOARCH)
	fmt.Fprintf(os.Stderr, "To run this container runtime on macOS, use Docker:\n")
	fmt.Fprintf(os.Stderr, "  docker compose run --rm runtime-lab\n")
	os.Exit(1)
}
