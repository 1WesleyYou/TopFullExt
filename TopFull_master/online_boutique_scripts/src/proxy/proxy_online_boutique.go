package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"github.com/elazarl/goproxy"
	"io/ioutil"
	"log"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/time/rate"
)

var (
	limiter            = rate.NewLimiter(70, 70)
	limitDir           string
	limiterTable       = make(map[string]*rate.Limiter)
	global_config_path = os.ExpandEnv("$HOME/TopFullExt/TopFull_master/online_boutique_scripts/src/global_config.json")
	global_config      Config
	mapStats           = make(map[string]*StatsModule)
	mapRejectStats     = make(map[string]*StatsModule)
	globalLock         *sync.Mutex
	proxyStartTime     time.Time
	emptycartDelayCfg  EmptyCartDelayConfig
	emptycartDelayLog  = "/tmp/topfull-emptycart-delay.log"
	emptycartLogLock   = &sync.Mutex{}
)

type EmptyCartDelayConfig struct {
	Enabled          bool
	EmptycartDelayMs int
	PostcartDelayMs  int
	JitterMs         int
	InjectAtS        int
	ReleaseAtS       int
}

type Config struct {
	ProxyDir    string   `json:"proxy_dir"`
	FrontendUrl string   `json:"frontend_url"`
	TargetAPI   []string `json:"record_target"`
}

type StatsModule struct {
	numReq           map[int64]int64
	lastReqTimestamp int64
	startTimestamp   int64
	localLock        *sync.Mutex
}

func (stats *StatsModule) reset() {
	stats.numReq = make(map[int64]int64)
	stats.lastReqTimestamp = 0
	stats.startTimestamp = time.Now().Unix()
	stats.localLock = &sync.Mutex{}
}

func (stats *StatsModule) logRequest() {
	stats.localLock.Lock()
	defer stats.localLock.Unlock()
	currentTime := time.Now().Unix()
	num, ok := stats.numReq[currentTime]
	if !ok {
		stats.numReq[currentTime] = 1
	} else {
		stats.numReq[currentTime] = num + 1
	}
	stats.lastReqTimestamp = currentTime
}

func (stats *StatsModule) currentRPS() float64 {
	stats.localLock.Lock()
	defer stats.localLock.Unlock()
	if stats.lastReqTimestamp == 0 {
		return 0
	}
	var startTime int64
	currentTime := time.Now().Unix()
	if currentTime-4 > stats.startTimestamp {
		startTime = currentTime - 4
	} else {
		startTime = stats.startTimestamp
	}

	var total int64
	total = 0
	for t := startTime; t < currentTime; t++ {
		req, ok := stats.numReq[t]
		if !ok {
			total += 0
		} else {
			total += req
		}
	}
	if currentTime-startTime == 0 {
		return 0
	} else {
		return float64(total) / float64(currentTime-startTime)
	}
}

func init() {
	b, err := ioutil.ReadFile(global_config_path)
	if err != nil {
		fmt.Println(err)
	}
	json.Unmarshal(b, &global_config)
	global_config.ProxyDir = os.ExpandEnv(global_config.ProxyDir)

	limitDir = global_config.ProxyDir

	for _, elem := range global_config.TargetAPI {
		limiterTable[elem] = rate.NewLimiter(10000, 10000)
		limiterTable[elem].SetBurst(10000)

		mapStats[elem] = &StatsModule{}
		mapStats[elem].reset()
		mapRejectStats[elem] = &StatsModule{}
		mapRejectStats[elem].reset()
	}

	globalLock = &sync.Mutex{}
	proxyStartTime = time.Now()
	emptycartDelayCfg = loadEmptyCartDelayConfig()
	rand.Seed(time.Now().UnixNano())
	initEmptycartDelayLog()

}

func getEnvOrDefault(key string, defaultValue string) string {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return defaultValue
	}
	return v
}

func getEnvIntOrDefault(key string, defaultValue int) int {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return defaultValue
	}
	out, err := strconv.Atoi(v)
	if err != nil {
		return defaultValue
	}
	return out
}

func getEnvIntWithFallback(primary string, fallback string, defaultValue int) int {
	v := strings.TrimSpace(os.Getenv(primary))
	if v != "" {
		out, err := strconv.Atoi(v)
		if err == nil {
			return out
		}
	}
	return getEnvIntOrDefault(fallback, defaultValue)
}

func loadEmptyCartDelayConfig() EmptyCartDelayConfig {
	emptycartDelayMs := getEnvIntWithFallback("EMPTYCART_DELAY_MS", "NET_DELAY_MS", 0)
	postcartDelayMs := getEnvIntWithFallback("POSTCART_DELAY_MS", "NET_DELAY_MS", 0)
	jitterMs := getEnvIntOrDefault("NET_JITTER_MS", 0)
	injectAtS := getEnvIntOrDefault("NET_INJECT_AT_SEC", 0)
	releaseAtS := getEnvIntOrDefault("NET_RELEASE_AT_SEC", 0)
	enableDefault := "0"
	if emptycartDelayMs > 0 || postcartDelayMs > 0 || jitterMs > 0 {
		enableDefault = "1"
	}
	enabled := getEnvOrDefault("API_DELAY_ENABLE", enableDefault) == "1"
	return EmptyCartDelayConfig{
		Enabled:          enabled,
		EmptycartDelayMs: emptycartDelayMs,
		PostcartDelayMs:  postcartDelayMs,
		JitterMs:         jitterMs,
		InjectAtS:        injectAtS,
		ReleaseAtS:       releaseAtS,
	}
}

func initEmptycartDelayLog() {
	_ = os.WriteFile(emptycartDelayLog, []byte(""), 0644)
	appendEmptycartDelayLog("system", "startup", 0, 0, "proxy_started")
}

func appendEmptycartDelayLog(api string, status string, elapsed int, delayMs int, reason string) {
	emptycartLogLock.Lock()
	defer emptycartLogLock.Unlock()
	f, err := os.OpenFile(emptycartDelayLog, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = fmt.Fprintf(
		f,
		"%s api=%s status=%s elapsed_s=%d delay_ms=%d reason=%s cfg_enabled=%t cfg_emptycart_delay_ms=%d cfg_postcart_delay_ms=%d cfg_jitter_ms=%d cfg_window=%d-%d\n",
		time.Now().Format(time.RFC3339Nano),
		api,
		status,
		elapsed,
		delayMs,
		reason,
		emptycartDelayCfg.Enabled,
		emptycartDelayCfg.EmptycartDelayMs,
		emptycartDelayCfg.PostcartDelayMs,
		emptycartDelayCfg.JitterMs,
		emptycartDelayCfg.InjectAtS,
		emptycartDelayCfg.ReleaseAtS,
	)
}

func sleepEmptycartDelayIfNeeded(api string) {
	elapsed := int(time.Since(proxyStartTime).Seconds())
	if !emptycartDelayCfg.Enabled {
		appendEmptycartDelayLog(api, "skip", elapsed, 0, "disabled")
		return
	}
	if emptycartDelayCfg.InjectAtS > 0 && elapsed < emptycartDelayCfg.InjectAtS {
		appendEmptycartDelayLog(api, "skip", elapsed, 0, "before_window")
		return
	}
	if emptycartDelayCfg.ReleaseAtS > emptycartDelayCfg.InjectAtS && elapsed > emptycartDelayCfg.ReleaseAtS {
		appendEmptycartDelayLog(api, "skip", elapsed, 0, "after_window")
		return
	}
	delayMs := emptycartDelayCfg.EmptycartDelayMs
	if api == "postcart" {
		delayMs = emptycartDelayCfg.PostcartDelayMs
	}
	if emptycartDelayCfg.JitterMs > 0 {
		delayMs += rand.Intn(emptycartDelayCfg.JitterMs + 1)
	}
	if delayMs > 0 {
		appendEmptycartDelayLog(api, "apply", elapsed, delayMs, "in_window")
		time.Sleep(time.Duration(delayMs) * time.Millisecond)
		return
	}
	appendEmptycartDelayLog(api, "skip", elapsed, 0, "non_positive_delay")
}

func monitorRPS() {
	fmt.Printf("Start monitoring\n")
	for true {
		time.Sleep(1 * time.Second)
		fmt.Printf("-------------------------\n")
		for _, elem := range global_config.TargetAPI {
			fmt.Printf("%s: %.1f ", elem, mapStats[elem].currentRPS())
			fmt.Printf("\n")
		}
	}
}

func changeLimitDelta() {
	dir, err := ioutil.ReadDir(limitDir)
	if err != nil {
		return
	}
	for _, fInfo := range dir {
		api := fInfo.Name()
		f, err := os.Open(limitDir + api)
		if err != nil {
			continue
		}
		defer f.Close()
		scanner := bufio.NewScanner(f)
		scanner.Scan()
		newRate, err := strconv.ParseFloat(scanner.Text(), 64)
		if err != nil {
			os.Remove(limitDir + api)
			continue
		}

		targetLimiter, ok := limiterTable[api]
		if !ok {
			println("Wrong API")
			os.Remove(limitDir + api)
			continue
		}
		currentRate := float64(targetLimiter.Limit())
		newRateFloat := newRate + currentRate
		if newRateFloat <= 0.0 {
			println("Too low threshold")
			os.Remove(limitDir + api)
			continue
		}

		targetLimiter.SetLimit(rate.Limit(newRateFloat))
		targetLimiter.SetBurst(int(newRateFloat))
		println("Apply threshold to ", api, " : ", newRateFloat)
		os.Remove(limitDir + api)
	}
}

func changeLimitAbs() {
	dir, err := ioutil.ReadDir(limitDir)
	if err != nil {
		println("Cannot read dir")
		return
	}
	for _, fInfo := range dir {
		api := fInfo.Name()
		f, err := os.Open(limitDir + api)
		if err != nil {
			println("Cannot open" + api)
			continue
		}
		defer f.Close()
		scanner := bufio.NewScanner(f)
		scanner.Scan()
		newRate, err := strconv.ParseFloat(scanner.Text(), 64)
		if err != nil {
			os.Remove(limitDir + api)
			print("Wrong rate")
			continue
		}

		targetLimiter, ok := limiterTable[api]
		if !ok {
			println("Wrong API")
			os.Remove(limitDir + api)
			continue
		}

		targetLimiter.SetLimit(rate.Limit(float64(newRate)))
		targetLimiter.SetBurst(int(newRate))
		println("Apply threshold to ", api, " : ", newRate)
		os.Remove(limitDir + api)
	}
}

func rejectByLimiter(api string, r *http.Request) (*http.Request, *http.Response) {
	mapStats[api].logRequest()
	if limiterTable[api].Allow() == false {
		mapRejectStats[api].logRequest()
		return r, goproxy.NewResponse(r, goproxy.ContentTypeText, http.StatusForbidden, "REJECT!")
	}
	return r, nil
}

func RejectGetproduct(r *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
	return rejectByLimiter("getproduct", r)
}
func RejectPostcheckout(r *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
	return rejectByLimiter("postcheckout", r)
}
func RejectGetcart(r *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
	return rejectByLimiter("getcart", r)
}
func RejectPostcart(r *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
	sleepEmptycartDelayIfNeeded("postcart")
	return rejectByLimiter("postcart", r)
}
func RejectEmptycart(r *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
	sleepEmptycartDelayIfNeeded("emptycart")
	return rejectByLimiter("emptycart", r)
}

func ReqStat(r *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
	target_apis := global_config.TargetAPI
	out := ""
	for _, elem := range target_apis {
		out += fmt.Sprintf("%s=%1.f/", elem, mapStats[elem].currentRPS())
	}

	return r, goproxy.NewResponse(r, goproxy.ContentTypeText, http.StatusOK, out)

}

func ReqThreshold(r *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
	out := ""
	apis := global_config.TargetAPI
	for _, elem := range apis {
		out += fmt.Sprintf("%s=%.1f/", elem, float64(limiterTable[elem].Limit()))
	}
	return r, goproxy.NewResponse(r, goproxy.ContentTypeText, http.StatusOK, out)
}

func ReqFailStats(r *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
	out := make(map[string]map[string]float64)
	apis := global_config.TargetAPI
	for _, elem := range apis {
		total := mapStats[elem].currentRPS()
		reject := mapRejectStats[elem].currentRPS()
		if reject > total {
			reject = total
		}
		accept := total - reject
		if accept < 0 {
			accept = 0
		}
		rejectRatio := 0.0
		if total > 0 {
			rejectRatio = reject / total
		}
		out[elem] = map[string]float64{
			"total_rps":    total,
			"reject_rps":   reject,
			"accept_rps":   accept,
			"reject_ratio": rejectRatio,
		}
	}
	body, err := json.Marshal(out)
	if err != nil {
		return r, goproxy.NewResponse(r, goproxy.ContentTypeText, http.StatusOK, "{}")
	}
	return r, goproxy.NewResponse(r, goproxy.ContentTypeText, http.StatusOK, string(body))
}

var GetCartCondition goproxy.ReqConditionFunc = func(req *http.Request, ctx *goproxy.ProxyCtx) bool {
	return req.URL.Host == global_config.FrontendUrl &&
		req.Method == "GET" &&
		req.URL.Path == "/cart"
}
var PostCartCondition goproxy.ReqConditionFunc = func(req *http.Request, ctx *goproxy.ProxyCtx) bool {
	return req.URL.Host == global_config.FrontendUrl &&
		req.Method == "POST" &&
		req.URL.Path == "/cart"
}
var PostCheckoutCondition goproxy.ReqConditionFunc = func(req *http.Request, ctx *goproxy.ProxyCtx) bool {
	return req.URL.Host == global_config.FrontendUrl &&
		req.Method == "POST" &&
		req.URL.Path == "/cart/checkout"
}
var GetProductCondition goproxy.ReqConditionFunc = func(req *http.Request, ctx *goproxy.ProxyCtx) bool {
	return req.URL.Host == global_config.FrontendUrl &&
		req.Method == "GET" &&
		strings.Contains(req.URL.Path, "/product")
}
var EmptyCartCondition goproxy.ReqConditionFunc = func(req *http.Request, ctx *goproxy.ProxyCtx) bool {
	return req.URL.Host == global_config.FrontendUrl &&
		req.Method == "POST" &&
		req.URL.Path == "/cart/empty"
}

var ReqStatCondition goproxy.ReqConditionFunc = func(req *http.Request, ctx *goproxy.ProxyCtx) bool {
	return req.Method == "GET" &&
		strings.Contains(req.URL.Path, "/stats")
}
var ReqThresholdCondition goproxy.ReqConditionFunc = func(req *http.Request, ctx *goproxy.ProxyCtx) bool {
	return req.Method == "GET" &&
		strings.Contains(req.URL.Path, "/thresholds")
}
var ReqFailStatsCondition goproxy.ReqConditionFunc = func(req *http.Request, ctx *goproxy.ProxyCtx) bool {
	return req.Method == "GET" &&
		strings.Contains(req.URL.Path, "/failstats")
}

func main() {
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGUSR1)
	go func() {
		for {
			sig := <-sigs
			println("Get signal", sig)
			changeLimitAbs()
		}
	}()

	go monitorRPS()

	proxy := goproxy.NewProxyHttpServer()
	proxy.Verbose = false
	proxy.Tr.MaxIdleConns = 50000
	proxy.Tr.MaxIdleConnsPerHost = 50000

	proxy.OnRequest(GetCartCondition).DoFunc(RejectGetcart)
	proxy.OnRequest(GetProductCondition).DoFunc(RejectGetproduct)
	proxy.OnRequest(PostCartCondition).DoFunc(RejectPostcart)
	proxy.OnRequest(EmptyCartCondition).DoFunc(RejectEmptycart)
	proxy.OnRequest(PostCheckoutCondition).DoFunc(RejectPostcheckout)

	proxy.OnRequest(ReqStatCondition).DoFunc(ReqStat)
	proxy.OnRequest(ReqThresholdCondition).DoFunc(ReqThreshold)
	proxy.OnRequest(ReqFailStatsCondition).DoFunc(ReqFailStats)
	println("Start")
	log.Fatal(http.ListenAndServe(":8090", proxy))
}
