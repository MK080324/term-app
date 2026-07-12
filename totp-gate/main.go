// totp-gate: 第二层认证 (独立于 Google 的 TOTP)。
//
// 它坐在 oauth2-proxy 后面、ttyd 前面:
//   oauth2-proxy(已验证 Google 身份, 通过 X-Forwarded-Email 传下来)
//     -> totp-gate(按 email 选对应用户, 校验其 TOTP, 发放 3 天 cookie)
//       -> 反代到该用户的 ttyd
//
// 只监听 127.0.0.1, 客户端无法直接连、也无法伪造 X-Forwarded-Email。
// 配置从 /etc/webterm/totp-gate.json 读取, 不含任何硬编码密钥。
package main

import (
	"crypto/hmac"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base32"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

type User struct {
	Email      string `json:"email"`
	Upstream   string `json:"upstream"`
	TOTPSecret string `json:"totp_secret"`
}

type Config struct {
	Listen         string `json:"listen"`
	CookieName     string `json:"cookie_name"`
	CookieHMACKey  string `json:"cookie_hmac_key"`
	CookieTTLHours int    `json:"cookie_ttl_hours"`
	Users          []User `json:"users"`
}

var (
	cfg         Config
	hmacKey     []byte
	proxies     = map[string]*httputil.ReverseProxy{}
	userByEmail = map[string]User{}
)

func main() {
	path := os.Getenv("TOTP_GATE_CONFIG")
	if path == "" {
		path = "/etc/webterm/totp-gate.json"
	}
	data, err := os.ReadFile(path)
	if err != nil {
		log.Fatal(err)
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		log.Fatal(err)
	}
	if cfg.CookieName == "" {
		cfg.CookieName = "_wt_totp"
	}
	if cfg.CookieTTLHours <= 0 {
		cfg.CookieTTLHours = 72
	}
	if cfg.CookieHMACKey == "" {
		log.Fatal("cookie_hmac_key 不能为空")
	}
	hmacKey = []byte(cfg.CookieHMACKey)
	for _, u := range cfg.Users {
		t, err := url.Parse(u.Upstream)
		if err != nil {
			log.Fatalf("用户 %s 的 upstream 非法: %v", u.Email, err)
		}
		proxies[u.Email] = httputil.NewSingleHostReverseProxy(t)
		userByEmail[u.Email] = u
	}
	http.HandleFunc("/", handler)
	log.Printf("totp-gate listening on %s (%d users)", cfg.Listen, len(cfg.Users))
	log.Fatal(http.ListenAndServe(cfg.Listen, nil))
}

func handler(w http.ResponseWriter, r *http.Request) {
	// X-Forwarded-Email 由 oauth2-proxy 设置。totp-gate 只监听 127.0.0.1,
	// 客户端够不到, 因此这个头可信。
	email := r.Header.Get("X-Forwarded-Email")
	u, ok := userByEmail[email]
	if !ok {
		http.Error(w, "403 unknown user: "+email, http.StatusForbidden)
		return
	}
	if r.URL.Path == "/__totp/verify" && r.Method == http.MethodPost {
		_ = r.ParseForm()
		if verifyTOTP(u.TOTPSecret, strings.TrimSpace(r.FormValue("code"))) {
			setCookie(w, u.Email)
			http.Redirect(w, r, "/", http.StatusFound)
			return
		}
		servePage(w, u.Email, "验证码错误，请重试")
		return
	}
	if cookieValid(r, email) {
		proxies[email].ServeHTTP(w, r)
		return
	}
	// TOTP 层未通过: WebSocket / 非 GET 直接拒, GET 给验证码页。
	if r.Method != http.MethodGet || strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
		http.Error(w, "401 TOTP required", http.StatusUnauthorized)
		return
	}
	servePage(w, email, "")
}

func setCookie(w http.ResponseWriter, email string) {
	exp := time.Now().Add(time.Duration(cfg.CookieTTLHours) * time.Hour).Unix()
	payload := email + "|" + strconv.FormatInt(exp, 10)
	val := base64.RawURLEncoding.EncodeToString([]byte(payload)) + "." + mac(payload)
	http.SetCookie(w, &http.Cookie{
		Name:     cfg.CookieName,
		Value:    val,
		Path:     "/",
		HttpOnly: true,
		Secure:   true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   cfg.CookieTTLHours * 3600,
	})
}

func cookieValid(r *http.Request, email string) bool {
	c, err := r.Cookie(cfg.CookieName)
	if err != nil {
		return false
	}
	parts := strings.SplitN(c.Value, ".", 2)
	if len(parts) != 2 {
		return false
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return false
	}
	payload := string(raw)
	if subtle.ConstantTimeCompare([]byte(mac(payload)), []byte(parts[1])) != 1 {
		return false
	}
	f := strings.SplitN(payload, "|", 2)
	if len(f) != 2 || f[0] != email {
		return false
	}
	exp, err := strconv.ParseInt(f[1], 10, 64)
	if err != nil {
		return false
	}
	return time.Now().Unix() < exp
}

func mac(payload string) string {
	m := hmac.New(sha256.New, hmacKey)
	m.Write([]byte(payload))
	return hex.EncodeToString(m.Sum(nil))
}

func verifyTOTP(secret, code string) bool {
	if len(code) != 6 {
		return false
	}
	secret = strings.ToUpper(strings.TrimSpace(secret))
	if p := len(secret) % 8; p != 0 {
		secret += strings.Repeat("=", 8-p)
	}
	key, err := base32.StdEncoding.DecodeString(secret)
	if err != nil {
		return false
	}
	counter := time.Now().Unix() / 30
	// 允许 ±1 个时间窗 (前后 30s), 抵消手机与服务器的时间偏差。
	for d := int64(-1); d <= 1; d++ {
		if subtle.ConstantTimeCompare([]byte(hotp(key, counter+d)), []byte(code)) == 1 {
			return true
		}
	}
	return false
}

func hotp(key []byte, counter int64) string {
	buf := make([]byte, 8)
	binary.BigEndian.PutUint64(buf, uint64(counter))
	m := hmac.New(sha1.New, key)
	m.Write(buf)
	sum := m.Sum(nil)
	off := sum[len(sum)-1] & 0x0f
	v := (int(sum[off])&0x7f)<<24 | (int(sum[off+1])&0xff)<<16 | (int(sum[off+2])&0xff)<<8 | (int(sum[off+3]) & 0xff)
	return fmt.Sprintf("%06d", v%1000000)
}

func servePage(w http.ResponseWriter, email, errMsg string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	p := strings.Replace(pageHTML, "{{ERR}}", errMsg, 1)
	p = strings.Replace(p, "{{EMAIL}}", email, 1)
	_, _ = w.Write([]byte(p))
}

const pageHTML = `<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>验证</title><style>
html,body{height:100%;margin:0;background:#1b1b1b;color:#eee;font-family:-apple-system,system-ui,sans-serif}
.box{height:100%;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:14px}
input{font-size:34px;letter-spacing:12px;width:230px;text-align:center;padding:10px;border-radius:10px;border:1px solid #444;background:#111;color:#fff}
.sub{color:#888;font-size:13px}.err{color:#e66;font-size:13px;height:16px}
</style></head><body><div class="box">
<div class="sub">{{EMAIL}}</div>
<form method="POST" action="/__totp/verify">
<input id="c" name="code" inputmode="numeric" pattern="[0-9]*" maxlength="6" autocomplete="one-time-code" autofocus placeholder="······">
</form>
<div class="err">{{ERR}}</div>
<div class="sub">输入 Aegis 中 term 的 6 位码</div>
<script>var i=document.getElementById('c');i.addEventListener('input',function(){if(i.value.length===6)i.form.submit()});</script>
</div></body></html>`
