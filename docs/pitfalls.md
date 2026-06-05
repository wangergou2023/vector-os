# Daima × Vector 集成踩坑记录

## 1. musl 64-bit time_t vs kernel 3.18（最大坑）

**现象**：daima-agent 用 musl-cross (GCC) 交叉编译为 ARM 静态链接二进制，在机器人上一启动就 SEGV，没有任何日志输出。

**根因**：musl libc 从 1.2.0 起在 32 位架构上强制使用 64-bit `time_t`。Linux kernel 3.18 (Vector 的内核版本) 只支持 32-bit 时间系统调用。musl 的 `sleep()`、`select()`、`clock_gettime()`、`pthread_cond_timedwait()` 等函数内部调用 `__clock_nanosleep_time64`、`__select_time64` 等 64-bit 系统调用，而这些 syscall 在 kernel 3.18 上不存在，直接 SEGV。

**调试历程**：
```
尝试1: 用宏替换 sleep/usleep/select/clock_gettime → SEGV (musl 内部也调用)
尝试2: 用内联汇编直接发 32-bit 系统调用 → SEGV (struct timeval 大小不匹配)
尝试3: 创建 daima_time32.h 全局覆盖 → SEGV (静态链接的 libcurl/libssl 内部也调用)
尝试4: 用 select() 替代 sleep() → SEGV (struct timeval 在 musl 上是 16 字节，kernel 期望 8 字节)
```

**最终方案**：放弃 musl，改用 **vicos-sdk** (Clang 20.1.8 + glibc sysroot)。victor 软件就是用这个工具链编译的，完美兼容 kernel 3.18。产物从 4.5MB 静态链接变为 271KB 动态链接，依赖机器人的 glibc。

```
编译: arm-oe-linux-gnueabi-clang --target=arm-oe-linux-gnueabi --sysroot=<vicos-sdk>/sysroot
产物: ELF 32-bit ARM, dynamically linked, interpreter /lib/ld-linux.so.3, for GNU/Linux 3.18.0
```

---

## 2. popen("r+") 不被支持

**现象**：daima 的 mcp_client 使用 `popen(cmd, "r+")` 启动 robot-mcp 子进程进行双向通信，但返回 `Invalid argument (errno=22)`。

**根因**：`popen("r+")` 不是 POSIX 标准（POSIX 只定义 "r" 和 "w"），Vector 的 BusyBox/glibc 不支持。

**方案**：改用 `fork() + exec() + pipe()` 手动创建子进程和双向管道。

```c
int to_child[2], from_child[2];
pipe(to_child); pipe(from_child);
pid_t pid = fork();
if (pid == 0) {
    dup2(to_child[0], STDIN_FILENO);
    dup2(from_child[1], STDOUT_FILENO);
    execve(bin_path, ...);
}
// Parent: fdopen(to_child[1], "w"), fdopen(from_child[0], "r")
```

---

## 3. mic_sock 连接被拒（反复踩坑）

**现象**：robot-mcp 绑定 `/dev/socket/mic_sock` 后，vic-anim 发送音频时持续报 `Connection refused`，日志中 611 条错误。

**根因**：vic-anim 和 vic-cloudless 使用特定的 Unix DGRAM socket 通信模式：
1. vic-anim 创建 `/dev/socket/mic_sock` 作为**服务器** (bind)
2. vic-cloudless 创建**客户端** socket，绑定到带名字的路径 (`/dev/socket/mic_sock_cp_mic`)，然后 connect 到服务器
3. vic-anim 从 `recvfrom()` 获取客户端地址，发送音频时 `sendto()` 到该客户端地址

**失败的尝试**：

| 尝试 | 方法 | 结果 |
|------|------|------|
| 1 | `net.ListenUnixgram` 绑定 mic_sock (服务器模式) | `Connection refused` — Go 的 DGRAM listener 使用了 connected-mode |
| 2 | `syscall.Socket + syscall.Bind` (原始 DGRAM) | `Connection refused` — 权限正确但 vic-anim 的 connect 失败 |
| 3 | `os.NewFile` 包装 fd | `Connection refused` — Go runtime 的 netpoller 干扰 |
| 4 | `net.Dial("unixgram", micSockPath)` (简单客户端) | 连上了但收不到数据 — 没有绑定客户端地址 |

**最终方案**：完全模仿 `NewUnixgramClient`：

```go
// 创建客户端 socket 并绑定到特定路径
syscall.Unlink("/dev/socket/mic_sock_rmcp")
cliAddr, _ := net.ResolveUnixAddr("unixgram", "/dev/socket/mic_sock_rmcp")
srvAddr, _ := net.ResolveUnixAddr("unixgram", "/dev/socket/mic_sock")
conn, _ := net.DialUnix("unixgram", cliAddr, srvAddr)

// 发送探测包让 vic-anim 记录我们的地址
conn.Write([]byte{3})  // CLAD ConnectionCheck
```

关键：客户端 socket 必须绑定到**带名字的路径**（`mic_sock_rmcp`），vic-anim 才能通过 `recvfrom()` 获取并记录这个地址。

---

## 4. vic-cloudless 阻塞 gateway 启动

**现象**：vic-cloudless 重启后，gRPC gateway (port 443) 无法启动，`netstat -tlnp` 没有 443 端口。

**根因**：`mainGateway()` goroutine 在启动 listener 之前先调用 `switchboardManager.Init()`，该函数会循环重试连接 vic-switchboard 的 Unix socket。当 switchboard socket 状态异常（旧进程残留的客户端 socket）时，`Init()` 无限阻塞，listener 永远不会被创建。

**日志特征**：
```
Couldn't create sockets for /dev/socket/_switchboard_gateway_server_ ... 
    connect: operation not permitted
```
每 5 秒重试一次，无限循环。

**方案**：清理残留的 switchboard 客户端 socket，重启 vic-switchboard，然后重启 vic-cloud。

```bash
rm -f /dev/socket/_switchboard_gateway_server__client
systemctl restart vic-switchboard
systemctl restart vic-cloud
# → "Listening on Port: 443"
```

---

## 5. 交叉编译工具链缺失

**现象**：macOS 上没有 ARM glibc 交叉编译器，Homebrew 只有 `arm-linux-gnueabihf-binutils`（链接器），没有 GCC。

**尝试过**：
- `brew install arm-linux-gnueabihf-gcc` → 不存在
- ARM 官方工具链 → 不提供 macOS 版
- musl-cross (Homebrew) → 有 GCC 但有 64-bit time 问题
- zig cc → 能交叉编译但依赖动态链接
- clang + 机器人 sysroot → 缺少 glibc 头文件（Yocto 剥离了 /usr/include）

**最终方案**：下载 **vicos-sdk**（Vector 官方的 ARM 交叉编译工具链）：

```bash
mkdir -p ~/.anki/vicos-sdk/dist/5.3.0-r07
cd ~/.anki/vicos-sdk/dist/5.3.0-r07
curl -sL "https://github.com/os-vector/wire-os-externals/releases/download/5.3.0-r07/vicos-sdk_5.3.0-r07_arm64-macos.tar.gz" | tar xz
# → 655MB, 包含 Clang 20.1.8 + glibc sysroot
```

这个工具链本身就是用来编译 victor (C++) 的，天然支持 ARM glibc、kernel 3.18 兼容。

---

## 6. 音频 relay 架构探索（多次试错）

**目标**：把 vic-anim 发出的 PCM 音频流转给 daima。

### 尝试1: FIFO 中继（依赖 vic-cloudless 重编译）

```
vic-anim → mic_sock → vic-cloudless (RelayAudio) → FIFO → robot-mcp → daima
```

**问题**：vic-cloudless 的 C 依赖（Vosk + WebRTC VAD + Opus）需要交叉编译 C 库。macOS 上 `make` 需要先跑 `build-voskopus.sh`（克隆 kaldi + OpenBLAS + clapack，编译 ~30 分钟 Git clone 反复失败）。

**放弃原因**：make 脚本在 macOS 上有 bug，多次 `git clone` 冲突。

### 尝试2: audio-relay C 程序（5.8KB，vicos-sdk 编译）

```
vic-anim → mic_sock → audio_relay (C) → FIFO → robot-mcp → daima
```

**问题**：audio_relay 用 `bind()` 创建 mic_sock，权限变成 `root:root`，vic-anim (engine:anki) 无法写入。

**修复**：`umask(0)` + `chown(0, 2901)` → 权限正确但 `Connection refused`（回到问题3）。

### 尝试3: audio-proxy (Go，socket 重命名)

```
vic-engine → mic_sock → audio-proxy → mic_sock_real → vic-cloudless
                                    → FIFO → daima
```

**问题**：需要重启 vic-cloudless 以连接到 renamed socket，但 vic-cloudless 的 switchboard 初始化阻塞了启动（问题4），且 socket 重命名后 vic-cloudless 无法正确重连。

### 最终方案: robot-mcp 直读 mic_sock

直接把 mic_sock 客户端功能合入 robot-mcp：

```
vic-anim → mic_sock → robot-mcp (DGRAM client) → MCP → daima
```

- 无需 FIFO ✓
- 无需额外进程 ✓
- 无需修改 vic-cloudless ✓
- 与 vic-cloudless 和平共存（都是客户端） ✓

---

## 7. BigModel ASR 需要 WAV 格式

**现象**：VAD 检测到语音，ASR flush 成功，但 BigModel API 返回 400：

```json
{"error":{"code":"1214","message":"transcriptions不支持当前文件格式"}}
```

**根因**：daima 的 `voice_channel_handle_audio()` 发送原始 PCM 字节，但 BigModel ASR 的 `transcriptions` API 期望有效的音频格式（WAV/MP3/OGG 等）。虽然设置了 `Content-Type: audio/wav`，但数据本身不是合法 WAV。

**方案**：在 vector_channel 的 `pcm_buf_flush_to_asr()` 中，发送 PCM 前手动构建 44 字节 WAV 头：

```c
// WAV header (little-endian)
memcpy(wav_buf,     "RIFF", 4);
*(uint32_t *)(wav_buf + 4)  = wav_size - 8;
memcpy(wav_buf + 8,  "WAVE", 4);
memcpy(wav_buf + 12, "fmt ", 4);
*(uint32_t *)(wav_buf + 16) = 16;         // PCM format
*(uint16_t *)(wav_buf + 20) = 1;          // uncompressed PCM
*(uint16_t *)(wav_buf + 22) = 1;          // mono
*(uint32_t *)(wav_buf + 24) = 16000;      // sample rate
// ... 省略其他字段 ...
memcpy(wav_buf + 36, "data", 4);
*(uint32_t *)(wav_buf + 40) = pcm_bytes;
memcpy(wav_buf + 44, pcm_data, pcm_bytes);
```

---

## 8. 空 ASR 结果导致 LLM API 报错

**现象**：连续说话时，部分音频段 ASR 返回空文本或单个字符（如 `"#"` ），这些空消息推入消息总线后被 LLM API 拒绝：

```json
{"error":{"message":"the message at position 5 with role 'user' must not be empty"}}
```

**方案**：在 `voice_channel_handle_audio()` 中过滤空/噪声 ASR 结果：

```c
/* 跳过空结果 */
if (!text[0]) return DAIMA_OK;
/* 跳过纯空白 */
char *t = text;
while (*t == ' ' || *t == '\t') t++;
if (!*t) return DAIMA_OK;
/* 跳过单字符噪声 (如 "#") */
if (strlen(t) <= 1 && (*t < 'A' || *t > 'z')) return DAIMA_OK;
```

---

## 9. rootfs 只读，systemd 服务无法持久化

**现象**：每次机器人重启后，daima 不自动启动。

**根因**：WireOS 的根文件系统是只读 ext4（squashfs/Yocto 构建）。`systemctl enable` 需要在 `/etc/systemd/system/` 创建 symlink，而这个目录是只读的。

**当前方案**：

```bash
# 使用 --runtime link（链接存在 /run/systemd/system/，tmpfs）
systemctl --runtime link /data/daima/daima.service

# 重启后 link 丢失，需要手动重建
# 变通：daima 启动时自动调用 system() 创建 link（已加入 daima_host.c）
```

**彻底方案**：预留——下次固件升级时把 daima.service 烧录进 rootfs。

---

## 10. VAD 参数调优

默认 VAD 参数对 Vector 的远场麦克风不够友好：

| 参数 | 默认 | 最终 |
|------|------|------|
| `VAD_SPEECH_THRESHOLD` | 400 RMS | 400 |
| `VAD_SILENCE_TIMEOUT` | 8 帧 (960ms) | 8 |
| `VAD_CHUNK_SAMPLES` | 1920 (120ms) | 1920 |

VAD 对短小语音（"Hey Vector"）有时切分不准——唤醒词和命令被分成多段。超时 flush 作为兜底机制（2 秒无新 chunk 自动提交）。

---

## 11. TTS 回复路由

**现象**：ASR → LLM 生成了回复文本，但机器人没出声。

**根因**：ASR 结果通过 `voice_channel_handle_audio()` 推到 `voice` 通道，LLM 回复通过 `voice_channel_send_reply()` 路由，调用 BigModel TTS → `audio_output_play_wav()` (stub, 无硬件输出)。

**方案**：在 `channel_runtime_send_text()` 中，voice 通道的 BigModel TTS 失败时，fallback 到 `vector_channel_send_reply()`，后者通过 MCP → robot-mcp → gRPC → vic-gateway → vic-engine 使用机器人内置 TTS (`robot_say_text`)。

---

## 12. PCM 音频传输瓶颈：base64 + stdio pipe

**现象**：BigModel TTS 生成 ~136KB PCM 数据后，机器人要等 49 秒才播放（且常常超时）。

**根因**：PCM 数据通过 MCP JSON-RPC over stdio pipe 传输，经历了三层放大：

```
136KB PCM → 181KB base64 → 182KB JSON → stdio pipe → bufio ReadBytes
```

1. **base64 编码**：136KB → 181KB (+33%)
2. **JSON 包装**：base64 嵌入 JSON 字符串 → 182KB
3. **stdio pipe 瓶颈**：Go `bufio.NewReader` 默认 4KB buffer，`ReadBytes('\n')` 读 182KB 需要 ~45 次 `read()` 系统调用，每次重新申请+拷贝 buffer (4096→8192→...→262144)，在慢速 ARM CPU 上实测耗时 **~19 秒**

**方案**：改用**文件传输**。daima 将 PCM 写入 `/tmp/daima_pcm_<pid>_<ts>.pcm`，MCP 只传 ~100 字节文件路径。robot-mcp 用 `os.ReadFile()` 直接读取。

```
之前: 136KB → base64 → 182KB JSON → pipe → 19s + gRPC 30s timeout = 49s
之后: 136KB → /tmp/file → MCP{100B path} → 2ms + gRPC = ~6s (音频时长)
```

```c
// daima (vector_channel.c)
FILE *fp = fopen("/tmp/daima_pcm_%d_%ld.pcm", "wb");
fwrite(send_pcm, 1, pcm_len, fp);
fclose(fp);
mcp_client_call_tool(mcp, "robot_play_pcm",
    "{\"pcm_file\":\"...\",\"sample_rate\":16000,\"volume\":100}", ...);
unlink(tmp_path);  // 播放完即删除
```

```go
// robot-mcp (tools.go)
data, _ := os.ReadFile(pcmFile)
tr.robot.PlayPCM(data, frameRate, volume)
```

---

## 13. gRPC 连接空闲超时

**现象**：PlayPCM 的 `ExternalAudioStreamPlayback` RPC 返回 `DeadlineExceeded`，且耗时远小于 30s 客户端 deadline（实测 4-8s）。

**根因**：Vector Gateway 会关闭空闲的 gRPC 连接。robot-mcp 启动后连接建立，但音频播放间的间隔（反馈回路中有 ~10 个 Working01 动画调用，持续 ~2 分钟）导致连接空闲。当 daima 调用 PlayPCM 时，TCP 连接已被 Gateway 断开，gRPC 传输层在重传超时后返回 DeadlineExceeded。

**方案**：添加 gRPC keepalive，每 10s 发送心跳 ping 保持连接活跃：

```go
grpc.WithKeepaliveParams(keepalive.ClientParameters{
    Time:                10 * time.Second,
    Timeout:             3 * time.Second,
    PermitWithoutStream: true,  // 无活跃 stream 也发 ping
})
```

---

## 14. 播放时自激反馈回路

**现象**：机器人说出 TTS 回复后，mic 拾取自身扬声器声音，触发 VAD → ASR → 新 LLM 对话 → 再次 TTS → 循环播放 Working01 思考动画。

**根因**：`vector_channel_play_pcm` 播放音频期间，`on_vector_audio` 仍在处理 mic 输入。TTS 生成的 PCM 通常 2-6 秒，足以触发多轮 VAD flush。

**方案**：播放期间静音 mic（跳过 VAD 处理），播放结束自动恢复：

```c
// 播放前
s_playing = true;
s_pcm_len = 0;         // 清空残留音频缓冲
s_speaking = false;
s_silence_frames = 0;

// 播放 (阻塞)
mcp_client_call_tool(mcp, "robot_play_pcm", args, ...);

// 播放后恢复
s_playing = false;
```

```c
// on_vector_audio 入口
pthread_mutex_lock(&s_mutex);
bool playing = s_playing;
pthread_mutex_unlock(&s_mutex);
if (playing) return;  // 跳过 VAD
```

---

## 15. gRPC 双向流需要 CloseSend

**现象**：连续两次 PlayPCM 调用时，第二次出现 `grpc: the client connection is closing`。

**根因**：`ExternalAudioStreamPlayback` 是双向流 RPC。客户端发送 Prepare → Chunks → Complete 后，必须调用 `CloseSend()` 通知服务器"我已发送完毕"，服务器才会发送 `PlaybackComplete`。未调用时服务器可能误解连接状态。

**方案**：在 `Recv()` 前添加 `CloseSend()`：

```go
stream.Send(&pb.ExternalAudioStreamRequest{
    AudioRequestType: &pb.ExternalAudioStreamRequest_AudioStreamComplete{...},
})
if err := stream.CloseSend(); err != nil {
    return err
}
resp, err := stream.Recv()  // 等待播放完成确认
```

---

## 时间线

| 阶段 | 耗时 | 内容 |
|------|------|------|
| 1 | 2h | 架构分析，设计 MCP bridge |
| 2 | 1h | 实现 robot-mcp (proto + gRPC + MCP) |
| 3 | 30m | daima 向量通道集成 |
| 4 | 3h | musl 交叉编译 + 64-bit time 踩坑 |
| 5 | 1h | vicos-sdk 下载 + daima glibc 编译 |
| 6 | 2h | mic_sock 连接被拒（反复试错） |
| 7 | 1h | audio relay 方案迭代 |
| 8 | 30m | WAV 头 + ASR 调试 |
| 9 | 30m | vic-cloud gateway 恢复 |
| 10 | 30m | TTS 路由 + 最终打通 |
| 11 | 2h | 音频播放优化 (PCM 文件传输 + gRPC keepalive + 播放静音) |
| **合计** | **~14h** | |

## 核心教训

1. **用正确的工具链**。Vector 的 victor 软件用 vicos-sdk (glibc Clang) 编译，任何 ARM 二进制都应优先用它，不要另起炉灶。

2. **理解 IPC 协议再动手**。vic-anim ↔ vic-cloudless 的 Unix DGRAM socket 通信有特定模式（named client socket + connect），模仿现有实现最保险。

3. **嵌入式系统的 rootfs 只读是常态**。持久化数据只能放 `/data`，系统服务需要固件级支持。

4. **日志是最好的调试工具**。每个失败的尝试都有日志佐证，逐步缩小问题范围。
