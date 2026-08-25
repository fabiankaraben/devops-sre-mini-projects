package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ANSI Color Codes
const (
	ColorReset   = "\033[0m"
	ColorBold    = "\033[1m"
	ColorDim     = "\033[2m"
	ColorRed     = "\033[0;31m"
	ColorGreen   = "\033[0;32m"
	ColorYellow  = "\033[0;33m"
	ColorBlue    = "\033[0;34m"
	ColorMagenta = "\033[0;35m"
	ColorCyan    = "\033[0;36m"
	ColorWhite   = "\033[1;37m"
)

var commonServices = map[int]string{
	21:    "FTP",
	22:    "SSH",
	23:    "Telnet",
	25:    "SMTP",
	53:    "DNS",
	80:    "HTTP",
	110:   "POP3",
	143:   "IMAP",
	443:   "HTTPS",
	465:   "SMTPS",
	587:   "Submission",
	993:   "IMAPS",
	995:   "POP3S",
	1433:  "MSSQL",
	1521:  "Oracle",
	3306:  "MySQL",
	3389:  "RDP",
	5432:  "PostgreSQL",
	6379:  "Redis",
	8000:  "HTTP-Alt",
	8080:  "HTTP-Proxy",
	8443:  "HTTPS-Alt",
	9000:  "Management",
	9022:  "SSH-Mock",
	9080:  "HTTP-Mock",
	9081:  "API-Mock",
	9200:  "Elasticsearch",
	9379:  "Redis-Mock",
	9432:  "Postgres-Mock",
	9843:  "HTTPS-Mock",
	9999:  "Filtered-Mock",
	27017: "MongoDB",
}

var portProfiles = map[string][]int{
	"common": {21, 22, 25, 53, 80, 110, 143, 443, 465, 587, 993, 995, 3306, 3389, 5432, 6379, 8000, 8080, 8443, 9000},
	"web":    {80, 443, 8000, 8080, 8443, 8888, 9080, 9081, 9843},
	"db":     {1433, 1521, 3306, 5432, 6379, 9200, 9432, 9379, 27017},
	"mock":   {9080, 9081, 9432, 9379, 9022, 9843, 9999},
	"top10":  {21, 22, 23, 25, 80, 110, 143, 443, 3306, 8080},
}

type PortResult struct {
	Host    string  `json:"host"`
	Port    int     `json:"port"`
	Service string  `json:"service"`
	State   string  `json:"state"` // OPEN, CLOSED, FILTERED, ERROR
	RTTMs   float64 `json:"rtt_ms"`
	Banner  string  `json:"banner"`
	Error   string  `json:"error,omitempty"`
}

type DNSBenchmark struct {
	Hostname    string   `json:"hostname"`
	ResolvedIPs []string `json:"resolved_ips"`
	LatencyMs   float64  `json:"latency_ms"`
	Error       string   `json:"error,omitempty"`
}

type ScanReport struct {
	Metadata struct {
		Timestamp       string  `json:"timestamp"`
		DurationSeconds float64 `json:"duration_seconds"`
		TotalProbes     int     `json:"total_probes"`
		OpenCount       int     `json:"open_count"`
		ClosedCount     int     `json:"closed_count"`
		FilteredCount   int     `json:"filtered_count"`
		ErrorCount      int     `json:"error_count"`
	} `json:"scan_metadata"`
	DNSBenchmarks []DNSBenchmark `json:"dns_benchmarks"`
	Results       []PortResult   `json:"results"`
}

func parsePorts(input string) []int {
	portMap := make(map[int]bool)
	tokens := strings.Split(input, ",")

	for _, token := range tokens {
		token = strings.TrimSpace(strings.ToLower(token))
		if token == "" {
			continue
		}

		if profile, ok := portProfiles[token]; ok {
			for _, p := range profile {
				portMap[p] = true
			}
		} else if strings.Contains(token, "-") {
			parts := strings.SplitN(token, "-", 2)
			startP, err1 := strconv.Atoi(parts[0])
			endP, err2 := strconv.Atoi(parts[1])
			if err1 == nil && err2 == nil {
				if startP > endP {
					startP, endP = endP, startP
				}
				for p := startP; p <= endP; p++ {
					if p >= 1 && p <= 65535 {
						portMap[p] = true
					}
				}
			}
		} else {
			if p, err := strconv.Atoi(token); err == nil && p >= 1 && p <= 65535 {
				portMap[p] = true
			}
		}
	}

	ports := make([]int, 0, len(portMap))
	for p := range portMap {
		ports = append(ports, p)
	}
	sort.Ints(ports)
	return ports
}

func expandTarget(target string) []string {
	target = strings.TrimSpace(target)
	if strings.Contains(target, "/") {
		_, ipNet, err := net.ParseCIDR(target)
		if err == nil {
			var ips []string
			for ip := ipNet.IP.Mask(ipNet.Mask); ipNet.Contains(ip); incIP(ip) {
				ips = append(ips, ip.String())
			}
			if len(ips) > 2 {
				// Return usable hosts
				return ips[1 : len(ips)-1]
			}
			return ips
		}
	}
	return []string{target}
}

func incIP(ip net.IP) {
	for j := len(ip) - 1; j >= 0; j-- {
		ip[j]++
		if ip[j] > 0 {
			break
		}
	}
}

func benchmarkDNS(hostname string) DNSBenchmark {
	bm := DNSBenchmark{
		Hostname:    hostname,
		ResolvedIPs: []string{},
	}

	if ip := net.ParseIP(hostname); ip != nil {
		bm.ResolvedIPs = []string{hostname}
		bm.LatencyMs = 0.0
		return bm
	}

	start := time.Now()
	ips, err := net.LookupIP(hostname)
	bm.LatencyMs = float64(time.Since(start).Microseconds()) / 1000.0

	if err != nil {
		bm.Error = err.Error()
	} else {
		for _, ip := range ips {
			bm.ResolvedIPs = append(bm.ResolvedIPs, ip.String())
		}
	}
	return bm
}

func probePort(host string, port int, timeout time.Duration) PortResult {
	svcName, ok := commonServices[port]
	if !ok {
		svcName = "Unknown"
	}

	res := PortResult{
		Host:    host,
		Port:    port,
		Service: svcName,
		State:   "UNKNOWN",
	}

	address := net.JoinHostPort(host, strconv.Itoa(port))
	start := time.Now()
	conn, err := net.DialTimeout("tcp", address, timeout)
	rtt := float64(time.Since(start).Microseconds()) / 1000.0
	res.RTTMs = rtt

	if err != nil {
		if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
			res.State = "FILTERED"
			res.Error = "Connection timed out (firewall drop)"
		} else if strings.Contains(err.Error(), "refused") {
			res.State = "CLOSED"
			res.Error = "Connection refused (TCP RST)"
		} else {
			res.State = "CLOSED"
			res.Error = err.Error()
		}
		return res
	}
	defer conn.Close()

	res.State = "OPEN"

	// Banner grab probe
	_ = conn.SetReadDeadline(time.Now().Add(400 * time.Millisecond))
	buf := make([]byte, 512)
	n, _ := conn.Read(buf)
	if n > 0 {
		banner := strings.TrimSpace(string(buf[:n]))
		lines := strings.Split(banner, "\n")
		if len(lines) > 0 {
			res.Banner = strings.TrimSpace(lines[0])
		}
	} else {
		// Send HTTP probe
		if port == 80 || port == 8080 || port == 9080 || port == 9081 {
			_ = conn.SetWriteDeadline(time.Now().Add(300 * time.Millisecond))
			_, _ = conn.Write([]byte(fmt.Sprintf("HEAD / HTTP/1.0\r\nHost: %s\r\n\r\n", host)))
			_ = conn.SetReadDeadline(time.Now().Add(400 * time.Millisecond))
			n, _ = conn.Read(buf)
			if n > 0 {
				respStr := string(buf[:n])
				for _, line := range strings.Split(respStr, "\r\n") {
					if strings.HasPrefix(strings.ToLower(line), "server:") {
						res.Banner = strings.TrimSpace(line)
						break
					}
				}
			}
		}
	}

	return res
}

func main() {
	targetFlag := flag.String("target", "", "Target host, IP or CIDR block")
	tShortFlag := flag.String("t", "", "Target host, IP or CIDR block (shorthand)")
	fileFlag := flag.String("file", "", "Target file path")
	fShortFlag := flag.String("f", "", "Target file path (shorthand)")
	portsFlag := flag.String("ports", "mock", "Port specification (e.g. 80,443, 8000-8010, mock, web, db, common)")
	pShortFlag := flag.String("p", "", "Port specification (shorthand)")
	timeoutFlag := flag.Float64("timeout", 1.0, "Connection timeout in seconds")
	concurrencyFlag := flag.Int("concurrency", 50, "Max concurrent worker goroutines")
	cShortFlag := flag.Int("c", 0, "Max concurrent worker goroutines (shorthand)")
	jsonFlag := flag.Bool("json", false, "Output results as JSON")
	jShortFlag := flag.Bool("j", false, "Output results as JSON (shorthand)")
	markdownFlag := flag.Bool("markdown", false, "Output results as Markdown")
	mShortFlag := flag.Bool("m", false, "Output results as Markdown (shorthand)")
	allFlag := flag.Bool("all", false, "Display all closed ports in output table")
	noFailFlag := flag.Bool("no-fail", false, "Always exit with code 0")

	flag.Parse()

	targetInput := *targetFlag
	if targetInput == "" {
		targetInput = *tShortFlag
	}

	fileInput := *fileFlag
	if fileInput == "" {
		fileInput = *fShortFlag
	}

	portInput := *portsFlag
	if *pShortFlag != "" {
		portInput = *pShortFlag
	}

	concurrency := *concurrencyFlag
	if *cShortFlag != 0 {
		concurrency = *cShortFlag
	}

	isJSON := *jsonFlag || *jShortFlag
	isMarkdown := *markdownFlag || *mShortFlag

	var rawTargets []string
	if targetInput != "" {
		for _, t := range strings.Split(targetInput, ",") {
			if strings.TrimSpace(t) != "" {
				rawTargets = append(rawTargets, strings.TrimSpace(t))
			}
		}
	}

	if fileInput != "" {
		file, err := os.Open(fileInput)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error opening target file: %v\n", err)
			os.Exit(3)
		}
		defer file.Close()

		scanner := bufio.NewScanner(file)
		for scanner.Scan() {
			line := strings.TrimSpace(scanner.Text())
			if line != "" && !strings.HasPrefix(line, "#") {
				rawTargets = append(rawTargets, line)
			}
		}
	}

	if len(rawTargets) == 0 {
		rawTargets = []string{"127.0.0.1"}
	}

	var allHosts []string
	for _, t := range rawTargets {
		allHosts = append(allHosts, expandTarget(t)...)
	}

	// Deduplicate hosts
	hostMap := make(map[string]bool)
	var dedupedHosts []string
	for _, h := range allHosts {
		if !hostMap[h] {
			hostMap[h] = true
			dedupedHosts = append(dedupedHosts, h)
		}
	}

	portsToScan := parsePorts(portInput)
	if len(portsToScan) == 0 {
		fmt.Fprintf(os.Stderr, "Error: Invalid port specification\n")
		os.Exit(3)
	}

	startTime := time.Now()

	// DNS Benchmarks
	var dnsBenchmarks []DNSBenchmark
	for _, h := range dedupedHosts {
		dnsBenchmarks = append(dnsBenchmarks, benchmarkDNS(h))
	}

	// Worker Pool for TCP Probing
	type job struct {
		host string
		port int
	}

	jobs := make(chan job, len(dedupedHosts)*len(portsToScan))
	resultsChan := make(chan PortResult, len(dedupedHosts)*len(portsToScan))

	timeoutDur := time.Duration(*timeoutFlag * float64(time.Second))
	var wg sync.WaitGroup

	for w := 0; w < concurrency; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := range jobs {
				resultsChan <- probePort(j.host, j.port, timeoutDur)
			}
		}()
	}

	for _, h := range dedupedHosts {
		for _, p := range portsToScan {
			jobs <- job{host: h, port: p}
		}
	}
	close(jobs)

	wg.Wait()
	close(resultsChan)

	var results []PortResult
	for r := range resultsChan {
		results = append(results, r)
	}

	sort.Slice(results, func(i, j int) bool {
		if results[i].Host == results[j].Host {
			return results[i].Port < results[j].Port
		}
		return results[i].Host < results[j].Host
	})

	durationSec := float64(time.Since(startTime).Microseconds()) / 1000000.0

	openCount, closedCount, filteredCount, errorCount := 0, 0, 0, 0
	for _, r := range results {
		switch r.State {
		case "OPEN":
			openCount++
		case "CLOSED":
			closedCount++
		case "FILTERED":
			filteredCount++
		case "ERROR":
			errorCount++
		}
	}

	if isJSON {
		report := ScanReport{}
		report.Metadata.Timestamp = time.Now().UTC().Format(time.RFC3339)
		report.Metadata.DurationSeconds = durationSec
		report.Metadata.TotalProbes = len(results)
		report.Metadata.OpenCount = openCount
		report.Metadata.ClosedCount = closedCount
		report.Metadata.FilteredCount = filteredCount
		report.Metadata.ErrorCount = errorCount
		report.DNSBenchmarks = dnsBenchmarks
		report.Results = results

		out, _ := json.MarshalIndent(report, "", "  ")
		fmt.Println(string(out))
	} else if isMarkdown {
		fmt.Println("# Network Port Scan & Troubleshooter Report (Go Edition)")
		fmt.Println()
		fmt.Printf("- **Timestamp**: `%s`\n", time.Now().UTC().Format(time.RFC3339))
		fmt.Printf("- **Duration**: `%.3f seconds`\n", durationSec)
		fmt.Printf("- **Total Probes**: `%d` (Open: `%d`, Closed: `%d`, Filtered: `%d`)\n\n", len(results), openCount, closedCount, filteredCount)

		fmt.Println("## Port Status Diagnostics")
		fmt.Println()
		fmt.Println("| Host | Port | Service | State | RTT (ms) | Banner / Diagnostic |")
		fmt.Println("| :--- | :--- | :--- | :--- | :--- | :--- |")
		for _, r := range results {
			details := r.Banner
			if details == "" {
				details = r.Error
			}
			fmt.Printf("| `%s` | `%d` | `%s` | **`%s`** | `%.2f ms` | %s |\n", r.Host, r.Port, r.Service, r.State, r.RTTMs, details)
		}
	} else {
		// CLI Table Output
		fmt.Printf("\n%s%s========================================================================================================%s\n", ColorBold, ColorBlue, ColorReset)
		fmt.Printf("%s%s                    NETWORK PORT SCANNER & TROUBLESHOOTER REPORT (GO EDITION)                           %s\n", ColorBold, ColorWhite, ColorReset)
		fmt.Printf("%s%s========================================================================================================%s\n", ColorBold, ColorBlue, ColorReset)
		fmt.Printf("Execution : %.3f seconds\n\n", durationSec)

		fmt.Printf("%s%-9s  %-20s  %-6s  %-14s  %-9s  %-35s%s\n", ColorBold, "STATE", "TARGET HOST", "PORT", "SERVICE", "RTT", "BANNER / DIAGNOSTIC", ColorReset)
		fmt.Printf("%s%s%s\n", ColorDim, strings.Repeat("-", 104), ColorReset)

		for _, r := range results {
			if !*allFlag && r.State == "CLOSED" && len(results) > 30 {
				continue
			}

			badge := fmt.Sprintf("%s[ %-6s]%s", ColorDim, r.State, ColorReset)
			if r.State == "OPEN" {
				badge = fmt.Sprintf("%s[ OPEN  ]%s", ColorGreen, ColorReset)
			} else if r.State == "FILTERED" {
				badge = fmt.Sprintf("%s[FILTER ]%s", ColorRed, ColorReset)
			}

			diag := r.Banner
			if diag == "" {
				diag = r.Error
			}
			if len(diag) > 45 {
				diag = diag[:42] + "..."
			}

			fmt.Printf("%s  %-20s  %-6d  %-14s  %-9.2f ms  %s\n", badge, r.Host, r.Port, r.Service, r.RTTMs, diag)
		}

		fmt.Printf("%s%s%s\n", ColorDim, strings.Repeat("-", 104), ColorReset)
		fmt.Printf("\n%sSUMMARY STATISTICS:%s\n", ColorBold, ColorReset)
		fmt.Printf("  Total Probes : %d\n", len(results))
		fmt.Printf("  %s✔ OPEN Ports   %s: %d\n", ColorGreen, ColorReset, openCount)
		fmt.Printf("  %s○ CLOSED Ports %s: %d\n", ColorDim, ColorReset, closedCount)
		fmt.Printf("  %s✖ FILTERED Port%s: %d\n", ColorRed, ColorReset, filteredCount)
		fmt.Printf("  Scan Duration: %.3fs\n\n", durationSec)
	}

	if *noFailFlag {
		os.Exit(0)
	}

	if errorCount > 0 {
		os.Exit(3)
	}

	os.Exit(0)
}
