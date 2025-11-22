package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/shirou/gopsutil/v3/cpu"
	"github.com/shirou/gopsutil/v3/disk"
	"github.com/shirou/gopsutil/v3/host"
	"github.com/shirou/gopsutil/v3/load"
	"github.com/shirou/gopsutil/v3/mem"
	"github.com/shirou/gopsutil/v3/net"
)

type MetricsSnapshot struct {
	CollectedAt    time.Time
	Host           string
	Platform       string
	Uptime         string
	Procs          uint64
	Hardware       HardwareInfo
	HealthScore    int     // 0-100 system health score
	HealthScoreMsg string  // Brief explanation

	CPU          CPUStatus
	GPU          []GPUStatus
	Memory       MemoryStatus
	Disks        []DiskStatus
	DiskIO       DiskIOStatus
	Network      []NetworkStatus
	Proxy        ProxyStatus
	Batteries    []BatteryStatus
	Thermal      ThermalStatus
	Sensors      []SensorReading
	Bluetooth    []BluetoothDevice
	TopProcesses []ProcessInfo
}

type HardwareInfo struct {
	Model      string // MacBook Pro 14-inch, 2021
	CPUModel   string // Apple M1 Pro / Intel Core i7
	TotalRAM   string // 16GB
	DiskSize   string // 512GB
	OSVersion  string // macOS Sonoma 14.5
}

type DiskIOStatus struct {
	ReadRate  float64 // MB/s
	WriteRate float64 // MB/s
}

type ProcessInfo struct {
	Name   string
	CPU    float64
	Memory float64
}

type CPUStatus struct {
	Usage      float64
	PerCore    []float64
	Load1      float64
	Load5      float64
	Load15     float64
	CoreCount  int
	LogicalCPU int
}

type GPUStatus struct {
	Name        string
	Usage       float64
	MemoryUsed  float64
	MemoryTotal float64
	Note        string
}

type MemoryStatus struct {
	Used        uint64
	Total       uint64
	UsedPercent float64
	SwapUsed    uint64
	SwapTotal   uint64
	Pressure    string // macOS memory pressure: normal/warn/critical
}

type DiskStatus struct {
	Mount       string
	Used        uint64
	Total       uint64
	UsedPercent float64
	Fstype      string
}

type NetworkStatus struct {
	Name      string
	RxRateMBs float64
	TxRateMBs float64
	IP        string
}

type ProxyStatus struct {
	Enabled bool
	Type    string // HTTP, SOCKS, System
	Host    string
}

type BatteryStatus struct {
	Percent    float64
	Status     string
	TimeLeft   string
	Health     string
	CycleCount int
}

type ThermalStatus struct {
	CPUTemp  float64
	GPUTemp  float64
	FanSpeed int
	FanCount int
}

type SensorReading struct {
	Label string
	Value float64
	Unit  string
	Note  string
}

type BluetoothDevice struct {
	Name      string
	Connected bool
	Battery   string
}

type Collector struct {
	prevNet    map[string]net.IOCountersStat
	lastNetAt  time.Time
	lastBTAt   time.Time
	lastBT     []BluetoothDevice
	lastGPUAt  time.Time
	cachedGPU  []GPUStatus
	prevDiskIO disk.IOCountersStat
	lastDiskAt time.Time
}

const (
	bluetoothCacheTTL     = 30 * time.Second
	systemProfilerTimeout = 4 * time.Second
	bluetoothctlTimeout   = 1500 * time.Millisecond
	macGPUInfoTTL         = 10 * time.Minute
)

var skipDiskMounts = map[string]bool{
	"/System/Volumes/VM":       true,
	"/System/Volumes/Preboot":  true,
	"/System/Volumes/Update":   true,
	"/System/Volumes/xarts":    true,
	"/System/Volumes/Hardware": true,
	"/System/Volumes/Data":     true,
	"/dev":                     true,
}

func NewCollector() *Collector {
	return &Collector{
		prevNet: make(map[string]net.IOCountersStat),
	}
}

func (c *Collector) Collect() (MetricsSnapshot, error) {
	now := time.Now()
	hostInfo, _ := host.Info()

	cpuStats, cpuErr := collectCPU()
	memStats, memErr := collectMemory()
	diskStats, diskErr := collectDisks()
	hwInfo := collectHardware(memStats.Total, diskStats)
	diskIO := c.collectDiskIO(now)
	netStats, netErr := c.collectNetwork(now)
	proxyStats := collectProxy()
	batteryStats, _ := collectBatteries()
	thermalStats := collectThermal()
	sensorStats, _ := collectSensors()
	gpuStats, gpuErr := c.collectGPU(now)
	btStats := c.collectBluetooth(now)
	topProcs := collectTopProcesses()

	var mergeErr error
	for _, e := range []error{cpuErr, memErr, diskErr, netErr, gpuErr} {
		if e != nil {
			if mergeErr == nil {
				mergeErr = e
			} else {
				mergeErr = fmt.Errorf("%v; %w", mergeErr, e)
			}
		}
	}

	// Calculate health score
	score, scoreMsg := calculateHealthScore(cpuStats, memStats, diskStats, diskIO, thermalStats)

	return MetricsSnapshot{
		CollectedAt:    now,
		Host:           hostInfo.Hostname,
		Platform:       fmt.Sprintf("%s %s", hostInfo.Platform, hostInfo.PlatformVersion),
		Uptime:         formatUptime(hostInfo.Uptime),
		Procs:          hostInfo.Procs,
		Hardware:       hwInfo,
		HealthScore:    score,
		HealthScoreMsg: scoreMsg,
		CPU:            cpuStats,
		GPU:            gpuStats,
		Memory:         memStats,
		Disks:          diskStats,
		DiskIO:         diskIO,
		Network:        netStats,
		Proxy:          proxyStats,
		Batteries:      batteryStats,
		Thermal:        thermalStats,
		Sensors:        sensorStats,
		Bluetooth:      btStats,
		TopProcesses:   topProcs,
	}, mergeErr
}

func calculateHealthScore(cpu CPUStatus, mem MemoryStatus, disks []DiskStatus, diskIO DiskIOStatus, thermal ThermalStatus) (int, string) {
	// Start with perfect score
	score := 100.0
	issues := []string{}

	// CPU Usage (30% weight) - deduct up to 30 points
	// 0-30% CPU = 0 deduction, 30-70% = linear, 70-100% = heavy penalty
	cpuPenalty := 0.0
	if cpu.Usage > 30 {
		if cpu.Usage > 70 {
			cpuPenalty = 30.0 * (cpu.Usage - 30) / 70.0
		} else {
			cpuPenalty = 15.0 * (cpu.Usage - 30) / 40.0
		}
	}
	score -= cpuPenalty
	if cpu.Usage > 70 {
		issues = append(issues, "High CPU")
	}

	// Memory Usage (25% weight) - deduct up to 25 points
	// 0-50% = 0 deduction, 50-80% = linear, 80-100% = heavy penalty
	memPenalty := 0.0
	if mem.UsedPercent > 50 {
		if mem.UsedPercent > 80 {
			memPenalty = 25.0 * (mem.UsedPercent - 50) / 50.0
		} else {
			memPenalty = 12.5 * (mem.UsedPercent - 50) / 30.0
		}
	}
	score -= memPenalty
	if mem.UsedPercent > 80 {
		issues = append(issues, "High Memory")
	}

	// Memory Pressure (extra penalty)
	if mem.Pressure == "warn" {
		score -= 5
		issues = append(issues, "Memory Pressure")
	} else if mem.Pressure == "critical" {
		score -= 15
		issues = append(issues, "Critical Memory")
	}

	// Disk Usage (20% weight) - deduct up to 20 points
	diskPenalty := 0.0
	if len(disks) > 0 {
		diskUsage := disks[0].UsedPercent
		if diskUsage > 70 {
			if diskUsage > 90 {
				diskPenalty = 20.0 * (diskUsage - 70) / 30.0
			} else {
				diskPenalty = 10.0 * (diskUsage - 70) / 20.0
			}
		}
		score -= diskPenalty
		if diskUsage > 90 {
			issues = append(issues, "Disk Almost Full")
		}
	}

	// Thermal (15% weight) - deduct up to 15 points
	thermalPenalty := 0.0
	if thermal.CPUTemp > 0 {
		if thermal.CPUTemp > 60 {
			if thermal.CPUTemp > 85 {
				thermalPenalty = 15.0
				issues = append(issues, "Overheating")
			} else {
				thermalPenalty = 15.0 * (thermal.CPUTemp - 60) / 25.0
			}
		}
		score -= thermalPenalty
	}

	// Disk IO (10% weight) - deduct up to 10 points
	ioPenalty := 0.0
	totalIO := diskIO.ReadRate + diskIO.WriteRate
	if totalIO > 50 {
		if totalIO > 150 {
			ioPenalty = 10.0
			issues = append(issues, "Heavy Disk IO")
		} else {
			ioPenalty = 10.0 * (totalIO - 50) / 100.0
		}
	}
	score -= ioPenalty

	// Ensure score is in valid range
	if score < 0 {
		score = 0
	}
	if score > 100 {
		score = 100
	}

	// Generate message
	msg := "Excellent"
	if score >= 90 {
		msg = "Excellent"
	} else if score >= 75 {
		msg = "Good"
	} else if score >= 60 {
		msg = "Fair"
	} else if score >= 40 {
		msg = "Poor"
	} else {
		msg = "Critical"
	}

	if len(issues) > 0 {
		msg = msg + ": " + strings.Join(issues, ", ")
	}

	return int(score), msg
}

func formatUptime(secs uint64) string {
	days := secs / 86400
	hours := (secs % 86400) / 3600
	mins := (secs % 3600) / 60
	if days > 0 {
		return fmt.Sprintf("%dd %dh %dm", days, hours, mins)
	}
	if hours > 0 {
		return fmt.Sprintf("%dh %dm", hours, mins)
	}
	return fmt.Sprintf("%dm", mins)
}

func collectCPU() (CPUStatus, error) {
	percents, err := cpu.Percent(0, true)
	if err != nil {
		return CPUStatus{}, err
	}
	if len(percents) == 0 {
		return CPUStatus{}, errors.New("cannot read CPU utilization")
	}
	totalPercent := 0.0
	for _, v := range percents {
		totalPercent += v
	}
	totalPercent /= float64(len(percents))

	loadAvg, _ := load.Avg()
	counts, _ := cpu.Counts(false)
	logical, _ := cpu.Counts(true)

	return CPUStatus{
		Usage:      totalPercent,
		PerCore:    percents,
		Load1:      loadAvg.Load1,
		Load5:      loadAvg.Load5,
		Load15:     loadAvg.Load15,
		CoreCount:  counts,
		LogicalCPU: logical,
	}, nil
}

func collectMemory() (MemoryStatus, error) {
	vm, err := mem.VirtualMemory()
	if err != nil {
		return MemoryStatus{}, err
	}

	swap, _ := mem.SwapMemory()
	pressure := getMemoryPressure()

	return MemoryStatus{
		Used:        vm.Used,
		Total:       vm.Total,
		UsedPercent: vm.UsedPercent,
		SwapUsed:    swap.Used,
		SwapTotal:   swap.Total,
		Pressure:    pressure,
	}, nil
}

func getMemoryPressure() string {
	if runtime.GOOS != "darwin" {
		return ""
	}
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	out, err := runCmd(ctx, "memory_pressure")
	if err != nil {
		return ""
	}
	lower := strings.ToLower(out)
	if strings.Contains(lower, "critical") {
		return "critical"
	}
	if strings.Contains(lower, "warn") {
		return "warn"
	}
	if strings.Contains(lower, "normal") {
		return "normal"
	}
	return ""
}

func collectDisks() ([]DiskStatus, error) {
	partitions, err := disk.Partitions(false)
	if err != nil {
		return nil, err
	}

	var (
		disks      []DiskStatus
		seenDevice = make(map[string]bool)
		seenVolume = make(map[string]bool)
	)
	for _, part := range partitions {
		if strings.HasPrefix(part.Device, "/dev/loop") {
			continue
		}
		if skipDiskMounts[part.Mountpoint] {
			continue
		}
		if strings.HasPrefix(part.Mountpoint, "/System/Volumes/") {
			continue
		}
		// Skip private volumes
		if strings.HasPrefix(part.Mountpoint, "/private/") {
			continue
		}
		if seenDevice[part.Device] {
			continue
		}
		usage, err := disk.Usage(part.Mountpoint)
		if err != nil || usage.Total == 0 {
			continue
		}
		// Skip small volumes (< 1GB)
		if usage.Total < 1<<30 {
			continue
		}
		// For APFS volumes, use a more precise dedup key (bytes level)
		// to handle shared storage pools properly
		volKey := fmt.Sprintf("%s:%d", part.Fstype, usage.Total)
		if seenVolume[volKey] {
			continue
		}
		disks = append(disks, DiskStatus{
			Mount:       part.Mountpoint,
			Used:        usage.Used,
			Total:       usage.Total,
			UsedPercent: usage.UsedPercent,
			Fstype:      part.Fstype,
		})
		seenDevice[part.Device] = true
		seenVolume[volKey] = true
	}

	sort.Slice(disks, func(i, j int) bool {
		return disks[i].Total > disks[j].Total
	})

	if len(disks) > 3 {
		disks = disks[:3]
	}

	return disks, nil
}

func (c *Collector) collectDiskIO(now time.Time) DiskIOStatus {
	counters, err := disk.IOCounters()
	if err != nil || len(counters) == 0 {
		return DiskIOStatus{}
	}

	var total disk.IOCountersStat
	for _, v := range counters {
		total.ReadBytes += v.ReadBytes
		total.WriteBytes += v.WriteBytes
	}

	if c.lastDiskAt.IsZero() {
		c.prevDiskIO = total
		c.lastDiskAt = now
		return DiskIOStatus{}
	}

	elapsed := now.Sub(c.lastDiskAt).Seconds()
	if elapsed <= 0 {
		elapsed = 1
	}

	readRate := float64(total.ReadBytes-c.prevDiskIO.ReadBytes) / 1024 / 1024 / elapsed
	writeRate := float64(total.WriteBytes-c.prevDiskIO.WriteBytes) / 1024 / 1024 / elapsed

	c.prevDiskIO = total
	c.lastDiskAt = now

	if readRate < 0 {
		readRate = 0
	}
	if writeRate < 0 {
		writeRate = 0
	}

	return DiskIOStatus{ReadRate: readRate, WriteRate: writeRate}
}

func collectTopProcesses() []ProcessInfo {
	if runtime.GOOS != "darwin" {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
	defer cancel()

	// Use ps to get top processes by CPU
	out, err := runCmd(ctx, "ps", "-Aceo", "pcpu,pmem,comm", "-r")
	if err != nil {
		return nil
	}

	lines := strings.Split(strings.TrimSpace(out), "\n")
	var procs []ProcessInfo
	for i, line := range lines {
		if i == 0 { // skip header
			continue
		}
		if i > 5 { // top 5
			break
		}
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		cpuVal, _ := strconv.ParseFloat(fields[0], 64)
		memVal, _ := strconv.ParseFloat(fields[1], 64)
		name := fields[len(fields)-1]
		// Get just the process name without path
		if idx := strings.LastIndex(name, "/"); idx >= 0 {
			name = name[idx+1:]
		}
		procs = append(procs, ProcessInfo{
			Name:   name,
			CPU:    cpuVal,
			Memory: memVal,
		})
	}
	return procs
}

func (c *Collector) collectNetwork(now time.Time) ([]NetworkStatus, error) {
	stats, err := net.IOCounters(true)
	if err != nil {
		return nil, err
	}

	// Get IP addresses for interfaces
	ifAddrs := getInterfaceIPs()

	if c.lastNetAt.IsZero() {
		c.lastNetAt = now
		for _, s := range stats {
			c.prevNet[s.Name] = s
		}
		return nil, nil
	}

	elapsed := now.Sub(c.lastNetAt).Seconds()
	if elapsed <= 0 {
		elapsed = 1
	}

	var result []NetworkStatus
	for _, cur := range stats {
		if isNoiseInterface(cur.Name) {
			continue
		}
		prev, ok := c.prevNet[cur.Name]
		if !ok {
			continue
		}
		rx := float64(cur.BytesRecv-prev.BytesRecv) / 1024.0 / 1024.0 / elapsed
		tx := float64(cur.BytesSent-prev.BytesSent) / 1024.0 / 1024.0 / elapsed
		if rx < 0 {
			rx = 0
		}
		if tx < 0 {
			tx = 0
		}
		result = append(result, NetworkStatus{
			Name:      cur.Name,
			RxRateMBs: rx,
			TxRateMBs: tx,
			IP:        ifAddrs[cur.Name],
		})
	}

	c.lastNetAt = now
	for _, s := range stats {
		c.prevNet[s.Name] = s
	}

	sort.Slice(result, func(i, j int) bool {
		return result[i].RxRateMBs+result[i].TxRateMBs > result[j].RxRateMBs+result[j].TxRateMBs
	})
	if len(result) > 3 {
		result = result[:3]
	}

	return result, nil
}

func getInterfaceIPs() map[string]string {
	result := make(map[string]string)
	ifaces, err := net.Interfaces()
	if err != nil {
		return result
	}
	for _, iface := range ifaces {
		for _, addr := range iface.Addrs {
			// Only IPv4
			if strings.Contains(addr.Addr, ".") && !strings.HasPrefix(addr.Addr, "127.") {
				ip := strings.Split(addr.Addr, "/")[0]
				result[iface.Name] = ip
				break
			}
		}
	}
	return result
}

func isNoiseInterface(name string) bool {
	lower := strings.ToLower(name)
	noiseList := []string{"lo", "awdl", "utun", "llw", "bridge", "gif", "stf", "xhc", "anpi", "ap"}
	for _, prefix := range noiseList {
		if strings.HasPrefix(lower, prefix) {
			return true
		}
	}
	return false
}

func collectBatteries() (batts []BatteryStatus, err error) {
	defer func() {
		if r := recover(); r != nil {
			// Swallow panics from platform-specific battery probes to keep the UI alive.
			err = fmt.Errorf("battery collection failed: %v", r)
		}
	}()

	// macOS: pmset
	if runtime.GOOS == "darwin" && commandExists("pmset") {
		if out, err := runCmd(context.Background(), "pmset", "-g", "batt"); err == nil {
			if batts := parsePMSet(out); len(batts) > 0 {
				return batts, nil
			}
		}
	}

	// Linux: /sys/class/power_supply
	matches, _ := filepath.Glob("/sys/class/power_supply/BAT*/capacity")
	for _, capFile := range matches {
		statusFile := filepath.Join(filepath.Dir(capFile), "status")
		capData, err := os.ReadFile(capFile)
		if err != nil {
			continue
		}
		statusData, _ := os.ReadFile(statusFile)
		percentStr := strings.TrimSpace(string(capData))
		percent, _ := strconv.ParseFloat(percentStr, 64)
		status := strings.TrimSpace(string(statusData))
		if status == "" {
			status = "Unknown"
		}
		batts = append(batts, BatteryStatus{
			Percent: percent,
			Status:  status,
		})
	}
	if len(batts) > 0 {
		return batts, nil
	}

	return nil, errors.New("no battery data found")
}

func collectSensors() ([]SensorReading, error) {
	temps, err := host.SensorsTemperatures()
	if err != nil {
		return nil, err
	}
	sort.Slice(temps, func(i, j int) bool {
		return temps[i].Temperature > temps[j].Temperature
	})
	var out []SensorReading
	for _, t := range temps {
		if t.Temperature <= 0 || t.Temperature > 150 {
			continue
		}
		out = append(out, SensorReading{
			Label: prettifyLabel(t.SensorKey),
			Value: t.Temperature,
			Unit:  "°C",
		})
	}
	return out, nil
}

func (c *Collector) collectGPU(now time.Time) ([]GPUStatus, error) {
	if runtime.GOOS == "darwin" {
		if len(c.cachedGPU) > 0 && !c.lastGPUAt.IsZero() && now.Sub(c.lastGPUAt) < macGPUInfoTTL {
			return c.cachedGPU, nil
		}
		if gpus, err := readMacGPUInfo(); err == nil && len(gpus) > 0 {
			c.cachedGPU = gpus
			c.lastGPUAt = now
			return gpus, nil
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 600*time.Millisecond)
	defer cancel()

	if !commandExists("nvidia-smi") {
		return []GPUStatus{{
			Name: "No GPU metrics available",
			Note: "Install nvidia-smi or use platform-specific metrics",
		}}, nil
	}

	out, err := runCmd(ctx, "nvidia-smi", "--query-gpu=utilization.gpu,memory.used,memory.total,name", "--format=csv,noheader,nounits")
	if err != nil {
		return nil, err
	}

	lines := strings.Split(strings.TrimSpace(out), "\n")
	var gpus []GPUStatus
	for _, line := range lines {
		fields := strings.Split(line, ",")
		if len(fields) < 4 {
			continue
		}
		util, _ := strconv.ParseFloat(strings.TrimSpace(fields[0]), 64)
		memUsed, _ := strconv.ParseFloat(strings.TrimSpace(fields[1]), 64)
		memTotal, _ := strconv.ParseFloat(strings.TrimSpace(fields[2]), 64)
		name := strings.TrimSpace(fields[3])

		gpus = append(gpus, GPUStatus{
			Name:        name,
			Usage:       util,
			MemoryUsed:  memUsed,
			MemoryTotal: memTotal,
		})
	}

	if len(gpus) == 0 {
		return []GPUStatus{{
			Name: "GPU read failed",
			Note: "Verify nvidia-smi availability",
		}}, nil
	}

	return gpus, nil
}

func (c *Collector) collectBluetooth(now time.Time) []BluetoothDevice {
	if len(c.lastBT) > 0 && !c.lastBTAt.IsZero() && now.Sub(c.lastBTAt) < bluetoothCacheTTL {
		return c.lastBT
	}

	if devs, err := readSystemProfilerBluetooth(); err == nil && len(devs) > 0 {
		c.lastBTAt = now
		c.lastBT = devs
		return devs
	}

	if devs, err := readBluetoothCTLDevices(); err == nil && len(devs) > 0 {
		c.lastBTAt = now
		c.lastBT = devs
		return devs
	}

	c.lastBTAt = now
	if len(c.lastBT) == 0 {
		c.lastBT = []BluetoothDevice{{Name: "No Bluetooth info", Connected: false}}
	}
	return c.lastBT
}

func readSystemProfilerBluetooth() ([]BluetoothDevice, error) {
	if runtime.GOOS != "darwin" || !commandExists("system_profiler") {
		return nil, errors.New("system_profiler unavailable")
	}

	ctx, cancel := context.WithTimeout(context.Background(), systemProfilerTimeout)
	defer cancel()

	out, err := runCmd(ctx, "system_profiler", "SPBluetoothDataType")
	if err != nil {
		return nil, err
	}
	return parseSPBluetooth(out), nil
}

func readBluetoothCTLDevices() ([]BluetoothDevice, error) {
	if !commandExists("bluetoothctl") {
		return nil, errors.New("bluetoothctl unavailable")
	}

	ctx, cancel := context.WithTimeout(context.Background(), bluetoothctlTimeout)
	defer cancel()

	out, err := runCmd(ctx, "bluetoothctl", "info")
	if err != nil {
		return nil, err
	}
	return parseBluetoothctl(out), nil
}

func readMacGPUInfo() ([]GPUStatus, error) {
	ctx, cancel := context.WithTimeout(context.Background(), systemProfilerTimeout)
	defer cancel()

	if !commandExists("system_profiler") {
		return nil, errors.New("system_profiler unavailable")
	}

	out, err := runCmd(ctx, "system_profiler", "-json", "SPDisplaysDataType")
	if err != nil {
		return nil, err
	}

	var data struct {
		Displays []struct {
			Name   string `json:"_name"`
			VRAM   string `json:"spdisplays_vram"`
			Vendor string `json:"spdisplays_vendor"`
			Metal  string `json:"spdisplays_metal"`
		} `json:"SPDisplaysDataType"`
	}
	if err := json.Unmarshal([]byte(out), &data); err != nil {
		return nil, err
	}

	var gpus []GPUStatus
	for _, d := range data.Displays {
		if d.Name == "" {
			continue
		}
		noteParts := []string{}
		if d.VRAM != "" {
			noteParts = append(noteParts, "VRAM "+d.VRAM)
		}
		if d.Metal != "" {
			noteParts = append(noteParts, d.Metal)
		}
		if d.Vendor != "" {
			noteParts = append(noteParts, d.Vendor)
		}
		note := strings.Join(noteParts, " · ")
		gpus = append(gpus, GPUStatus{
			Name:  d.Name,
			Usage: -1,
			Note:  note,
		})
	}

	if len(gpus) == 0 {
		return []GPUStatus{{
			Name: "GPU info unavailable",
			Note: "Unable to parse system_profiler output",
		}}, nil
	}

	return gpus, nil
}

func runCmd(ctx context.Context, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	output, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return string(output), nil
}

func commandExists(name string) bool {
	if name == "" {
		return false
	}
	defer func() {
		if r := recover(); r != nil {
			// If LookPath panics due to permissions or platform quirks, act as if the command is missing.
		}
	}()
	_, err := exec.LookPath(name)
	return err == nil
}

func parseSPBluetooth(raw string) []BluetoothDevice {
	lines := strings.Split(raw, "\n")
	var devices []BluetoothDevice
	var currentName string
	var connected bool
	var battery string

	for _, line := range lines {
		trim := strings.TrimSpace(line)
		if len(trim) == 0 {
			continue
		}
		if !strings.HasPrefix(line, "    ") && strings.HasSuffix(trim, ":") {
			// Reset at top-level sections
			currentName = ""
			connected = false
			battery = ""
			continue
		}
		if strings.HasPrefix(line, "        ") && strings.HasSuffix(trim, ":") {
			if currentName != "" {
				devices = append(devices, BluetoothDevice{Name: currentName, Connected: connected, Battery: battery})
			}
			currentName = strings.TrimSuffix(trim, ":")
			connected = false
			battery = ""
			continue
		}
		if strings.Contains(trim, "Connected:") {
			connected = strings.Contains(trim, "Yes")
		}
		if strings.Contains(trim, "Battery Level:") {
			battery = strings.TrimSpace(strings.TrimPrefix(trim, "Battery Level:"))
		}
	}
	if currentName != "" {
		devices = append(devices, BluetoothDevice{Name: currentName, Connected: connected, Battery: battery})
	}
	if len(devices) == 0 {
		return []BluetoothDevice{{Name: "No devices", Connected: false}}
	}
	return devices
}

func parseBluetoothctl(raw string) []BluetoothDevice {
	lines := strings.Split(raw, "\n")
	var devices []BluetoothDevice
	current := BluetoothDevice{}
	for _, line := range lines {
		trim := strings.TrimSpace(line)
		if strings.HasPrefix(trim, "Device ") {
			if current.Name != "" {
				devices = append(devices, current)
			}
			current = BluetoothDevice{Name: strings.TrimPrefix(trim, "Device "), Connected: false}
		}
		if strings.HasPrefix(trim, "Name:") {
			current.Name = strings.TrimSpace(strings.TrimPrefix(trim, "Name:"))
		}
		if strings.HasPrefix(trim, "Connected:") {
			current.Connected = strings.Contains(trim, "yes")
		}
	}
	if current.Name != "" {
		devices = append(devices, current)
	}
	if len(devices) == 0 {
		return []BluetoothDevice{{Name: "No devices", Connected: false}}
	}
	return devices
}

func parsePMSet(raw string) []BatteryStatus {
	lines := strings.Split(raw, "\n")
	var out []BatteryStatus
	var timeLeft string

	for _, line := range lines {
		// Check for time remaining
		if strings.Contains(line, "remaining") {
			// Extract time like "1:30 remaining"
			parts := strings.Fields(line)
			for i, p := range parts {
				if p == "remaining" && i > 0 {
					timeLeft = parts[i-1]
				}
			}
		}

		if !strings.Contains(line, "%") {
			continue
		}
		fields := strings.Fields(line)
		var (
			percent float64
			found   bool
			status  = "Unknown"
		)
		for i, f := range fields {
			if strings.Contains(f, "%") {
				value := strings.TrimSuffix(strings.TrimSuffix(f, ";"), "%")
				if p, err := strconv.ParseFloat(value, 64); err == nil {
					percent = p
					found = true
					if i+1 < len(fields) {
						status = strings.TrimSuffix(fields[i+1], ";")
					}
				}
				break
			}
		}
		if !found {
			continue
		}

		// Get battery health and cycle count
		health, cycles := getBatteryHealth()

		out = append(out, BatteryStatus{
			Percent:    percent,
			Status:     status,
			TimeLeft:   timeLeft,
			Health:     health,
			CycleCount: cycles,
		})
	}
	return out
}

func getBatteryHealth() (string, int) {
	if runtime.GOOS != "darwin" {
		return "", 0
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	out, err := runCmd(ctx, "system_profiler", "SPPowerDataType")
	if err != nil {
		return "", 0
	}

	var health string
	var cycles int

	lines := strings.Split(out, "\n")
	for _, line := range lines {
		lower := strings.ToLower(line)
		if strings.Contains(lower, "cycle count") {
			parts := strings.Split(line, ":")
			if len(parts) == 2 {
				cycles, _ = strconv.Atoi(strings.TrimSpace(parts[1]))
			}
		}
		if strings.Contains(lower, "condition") {
			parts := strings.Split(line, ":")
			if len(parts) == 2 {
				health = strings.TrimSpace(parts[1])
			}
		}
	}
	return health, cycles
}

func collectThermal() ThermalStatus {
	if runtime.GOOS != "darwin" {
		return ThermalStatus{}
	}

	var thermal ThermalStatus

	// Get fan info from system_profiler
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	out, err := runCmd(ctx, "system_profiler", "SPPowerDataType")
	if err == nil {
		lines := strings.Split(out, "\n")
		for _, line := range lines {
			lower := strings.ToLower(line)
			if strings.Contains(lower, "fan") && strings.Contains(lower, "speed") {
				parts := strings.Split(line, ":")
				if len(parts) == 2 {
					// Extract number from string like "1200 RPM"
					numStr := strings.TrimSpace(parts[1])
					numStr = strings.Split(numStr, " ")[0]
					thermal.FanSpeed, _ = strconv.Atoi(numStr)
				}
			}
		}
	}

	// Try to get CPU temperature using sudo powermetrics (may not work without sudo)
	// Fallback: use SMC reader or estimate from thermal pressure
	ctx2, cancel2 := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel2()

	// Try thermal level as a proxy
	out2, err := runCmd(ctx2, "sysctl", "-n", "machdep.xcpm.cpu_thermal_level")
	if err == nil {
		level, _ := strconv.Atoi(strings.TrimSpace(out2))
		// Estimate temp: level 0-100 roughly maps to 40-100°C
		if level >= 0 {
			thermal.CPUTemp = 45 + float64(level)*0.5
		}
	}

	return thermal
}

func prettifyLabel(key string) string {
	key = strings.TrimSpace(key)
	key = strings.TrimPrefix(key, "TC")
	key = strings.ReplaceAll(key, "_", " ")
	return key
}

func collectProxy() ProxyStatus {
	// Check environment variables first
	for _, env := range []string{"https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY"} {
		if val := os.Getenv(env); val != "" {
			proxyType := "HTTP"
			if strings.HasPrefix(val, "socks") {
				proxyType = "SOCKS"
			}
			// Extract host
			host := val
			if strings.Contains(host, "://") {
				host = strings.SplitN(host, "://", 2)[1]
			}
			if idx := strings.Index(host, "@"); idx >= 0 {
				host = host[idx+1:]
			}
			return ProxyStatus{Enabled: true, Type: proxyType, Host: host}
		}
	}

	// macOS: check system proxy via scutil
	if runtime.GOOS == "darwin" {
		ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
		defer cancel()
		out, err := runCmd(ctx, "scutil", "--proxy")
		if err == nil {
			if strings.Contains(out, "HTTPEnable : 1") || strings.Contains(out, "HTTPSEnable : 1") {
				return ProxyStatus{Enabled: true, Type: "System", Host: "System Proxy"}
			}
			if strings.Contains(out, "SOCKSEnable : 1") {
				return ProxyStatus{Enabled: true, Type: "SOCKS", Host: "System Proxy"}
			}
		}
	}

	return ProxyStatus{Enabled: false}
}

func collectHardware(totalRAM uint64, disks []DiskStatus) HardwareInfo {
	if runtime.GOOS != "darwin" {
		return HardwareInfo{
			Model:     "Unknown",
			CPUModel:  runtime.GOARCH,
			TotalRAM:  humanBytes(totalRAM),
			DiskSize:  "Unknown",
			OSVersion: runtime.GOOS,
		}
	}

	// Get model and CPU from system_profiler
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	var model, cpuModel, osVersion string

	// Get hardware overview
	out, err := runCmd(ctx, "system_profiler", "SPHardwareDataType")
	if err == nil {
		lines := strings.Split(out, "\n")
		for _, line := range lines {
			lower := strings.ToLower(strings.TrimSpace(line))
			// Prefer "Model Name" over "Model Identifier"
			if strings.Contains(lower, "model name:") {
				parts := strings.Split(line, ":")
				if len(parts) == 2 {
					model = strings.TrimSpace(parts[1])
				}
			}
			if strings.Contains(lower, "chip:") {
				parts := strings.Split(line, ":")
				if len(parts) == 2 {
					cpuModel = strings.TrimSpace(parts[1])
				}
			}
			if strings.Contains(lower, "processor name:") && cpuModel == "" {
				parts := strings.Split(line, ":")
				if len(parts) == 2 {
					cpuModel = strings.TrimSpace(parts[1])
				}
			}
		}
	}

	// Get macOS version
	ctx2, cancel2 := context.WithTimeout(context.Background(), 1*time.Second)
	defer cancel2()
	out2, err := runCmd(ctx2, "sw_vers", "-productVersion")
	if err == nil {
		osVersion = "macOS " + strings.TrimSpace(out2)
	}

	// Get disk size
	diskSize := "Unknown"
	if len(disks) > 0 {
		diskSize = humanBytes(disks[0].Total)
	}

	return HardwareInfo{
		Model:     model,
		CPUModel:  cpuModel,
		TotalRAM:  humanBytes(totalRAM),
		DiskSize:  diskSize,
		OSVersion: osVersion,
	}
}

