# wire-os 协议与数据结构溯源

本文档记录项目中各子系统的协议定义、数据格式及其在源码中的位置，方便后续开发查证。

---

## 1. CLAD 消息协议

CLAD (C-Like Algebraic Data) 是 Anki 自研的序列化框架，定义在 `.clad` 文件中。

### 1.1 消息标签 (Tag) 体系

**定义位置**: `anki/victor/robot/clad/src/clad/robotInterface/messageRobotToEngine.clad`

| Tag   | 消息类型          | 方向       | 说明                               |
|-------|-------------------|-----------|------------------------------------|
| 0x01  | MicData           | Robot→Anim | 4 通道原始麦克风数据              |
| 0x02  | Audio Done        | Robot→Anim | VAD 检测到说话结束                 |
| 0x03  | ConnectionCheck   | 双向       | 心跳/连接探测                      |
| 0xDA  | MicDirection      | Robot→Engine| 声源定位方向数据                  |
| 0xD9  | TriggerWordDetected | Robot→Engine | 唤醒词检测                       |
| 0xF0  | RobotState        | Robot→Engine| 机器人状态 (轮速/角度等)          |
| 0xF2  | MicData (另)      | Robot→Engine| 4 通道原始音频 (引擎端)           |

**注意**: 0x01/0x03 是 `mic_sock` DGRAM 层面用的小 tag（1 字节），与 CLAD union 的大 tag 体系不完全一致。Anim/Syscon 之间的 tag 映射需参考 `messageEngineToRobot.clad`。

### 1.2 核心消息定义

#### MicDirection
```
tag = 0xDA (218)
size = 76 bytes (不含 tag)

Offset  Size   Type       Field
  0      4     uint32     timestamp
  4      2     uint16     direction          // 最强声源方向 (0-11)
  6      2     int16      confidence         // 最强方向置信度
  8      2     uint16     selectedDirection  // 波束选择方向
 10      2     int16      selectedConfidence // 选中方向置信度
 12     52     float32[13] confidenceList    // 全部13方向置信度
 64      4     int32      activeState        // VAD 活跃状态
 68      4     float32    latestPowerValue   // 最近功率值
 72      4     float32    latestNoiseFloor   // 底噪值
```

方向索引 (12 + 1 overhead):
```
  0 = 正前 (0°)
  1 = 右前 (30° CCW)
  2 = 右侧 (60°)
  ...
  6 = 正后 (180°)
  ...
 11 = 左前 (330°)
 12 = 头顶
```

方向角换算: `degrees = dir_idx * 30`

#### MicData (mic_sock 用)
```
tag = 0x01
format: [tag:1][length:2][int16 data[length]]  (length = sample_count, not byte_count)

raw 4ch 格式: data[640] int16, 10ms @ 16kHz, interleaved channels
```

#### AudioDone
```
tag = 0x02
format: [tag:1]  (无 payload)
```

### 1.3 Union 定义

**文件**: `anki/victor/robot/clad/src/clad/robotInterface/messageRobotToEngine.clad:180`

```clad
union RobotToEngine {
  SyncRobotAck               syncRobotAck           = 0xB0,
  ...
  TriggerWordDetected        triggerWordDetected    = 0xD9,
  MicDirection               micDirection           = 0xDA,
  ...
  RobotState                 state                  = 0xF0,
  MicData                    micData                = 0xF2,
}
```

---

## 2. 音频处理架构

### 2.1 4 麦克风波束成形

**核心 DSP**: Signal Essence (SE) 闭源库  
**路径**: `anki/victor/3rd/signalEssence/v009/vicos/project/anki_victor/`

```
硬件 4 麦 → SE 波束成形 → MMIfProcessMicrophones()
              ├─ 搜索波束 (delay-and-sum): 方向查找 + 置信度
              └─ 空间滤波波束 (differential beamforming): 定向增强

animProcess → MicDataProcessor (ProcessingState 状态机)
              ├─ SigEsBeamformingOn:   波束成形在线, 方向数据可用
              └─ SigEsBeamformingOff:  回退混合模式, 方向数据可能不准
```

**关键常量**: `anki/victor/lib/micData/micDataTypes.h`
```cpp
kNumInputChannels = 4                     // 4 麦
kSamplesPerBlockPerChannel = 160          // 每通道 160 样本
kSampleRateIncoming_hz = 16000            // 16000 Hz
kIncomingAudioChunkSize = 640             // 4ch * 160 = 640 采样
kNumDirections = 13                       // 12 水平 + 1 头顶
```

### 2.2 音频处理模式

**定义位置**: `anki/victor/tools/protobuf/gateway/public/messages.proto:996`

| 模式                        | 值 | 说明                                         |
|-----------------------------|----|----------------------------------------------|
| AUDIO_UNKNOWN               | 0  | 未知                                        |
| AUDIO_OFF                   | 1  | 关闭                                        |
| AUDIO_FAST_MODE             | 2  | 单麦原始数据                                 |
| AUDIO_DIRECTIONAL_MODE      | 3  | 波束成形定向增强 (最干净，适合听写)           |
| AUDIO_VOICE_DETECT_MODE     | 4  | 多麦非波束 (语音检测最佳，同时算方向和底噪)    |

> source: `anki/victor/cloud/cloud/message_handler.go:2480`  
> "AUDIO_VOICE_DETECT_MODE has been identified as the best for voice detection"

### 2.3 mic_sock 通信

```
vic-anim   ←→   /dev/socket/mic_sock (DGRAM server)
                          ↑
          ┌───────────────┴────────────────┐
          │                                │
   vic-cloudless (原始)           robot-mcp (我们的实现)
   /dev/socket/mic_sock_client    /dev/socket/mic_sock_rmcp
```

**连线时序**:
1. robot-mcp 创建 `mic_sock_rmcp` client socket
2. DGRAM connect 到 `mic_sock` server
3. 发送 `tag=3` (ConnectionCheck) 让 vic-anim 记住 client 地址
4. vic-anim 通过 `recvfrom()` 获取 client 地址后，向其发送 Audio/AudioDone/MicDirection

**robot-mcp 端**: `robot-mcp/audio.go`
- Audio (tag=1): base64 编码后通过 MCP 通知 `notifications/audio/chunk` 发送
- AudioDone (tag=2): 通 `notifications/audio/done`
- MicDirection (tag=0xDA): 缓存最新方向，注入 done 通知 + 提供 `mic_get_direction` 工具

---

## 3. PCM 播放管线

### 3.1 daima → robot-mcp 传输

**方式**: Unix stream socket `/tmp/daima_spk.sock`

```
daima-agent                        robot-mcp
  │                                   │
  ├─ connect /tmp/daima_spk.sock ────→│ listener + goroutine accept
  ├─ write uint32 seq (LE) ──────────→│ binary.Read seq
  ├─ write PCM raw data ─────────────→│ io.ReadAll pcm
  ├─ close ──────────────────────────→│ defer conn.Close()
  │                                   │ spkQueue ← pcmJob{seq, pcm}
  │                                   │
  │                          worker goroutine:
  │                           sort.Slice → 按 seq 保序
  │                           spkPlay(pcm) → gRPC ExternalAudioStreamPlayback
```

### 3.2 gRPC ExternalAudioStreamPlayback 时序

```
Prepare (16000Hz, volume=100)
  │
  ├─ Chunk 1 (maxChunk=1024 bytes) → sleep 25ms
  ├─ Chunk 2 → sleep 25ms
  ├─ ...
  └─ Complete
       │
       └─ sleep(remain): audio_duration - stream_time (最少 50ms)
```

> **要点**: 这是 fire-and-forget 流——不需要 Recv，Send 完数据后只需等音频播完的残余时间。

### 3.3 PCM 音频处理

**位置**: `daima-agent/main/voice/tts_player.c`

```
TTS 输出 (24000Hz)
  │
  ├─ 降采样到 16000Hz  (voice_channel.c, WAV 解析)
  ├─ 增益 2x            (apply_gain)
  └─ 低通滤波 4kHz      (apply_lowpass, RC 一阶)
```

---

## 4. TTS 与 ASR 协议

### 4.1 BigModel API

| 接口   | URL                                          | 并发 | 超时  |
|--------|----------------------------------------------|------|-------|
| TTS    | `https://open.bigmodel.cn/api/paas/v4/audio/speech` | 5    | 30s   |
| ASR    | `https://open.bigmodel.cn/api/paas/v4/audio/transcriptions` | - | 120s  |

**TTS 输出**: WAV 格式, 24000Hz, 16bit, mono

**实现**: `daima-agent/main/voice/voice_channel.c`

### 4.2 TTS 分句策略

**位置**: `daima-agent/main/voice/tts_player.c`

```
SOFT_LIMIT = 24 字
MAX_SENTENCES = 3 句并行

≤24 字 → 整句一次 TTS
>24 字 → 按 。！？.!? 切分，取前 3 句并行
```

并行机制: pthread 多线程同时调 BigModel，主线程 `pthread_join` 等待后按序 push socket。

---

## 5. gRPC 服务

### 5.1 连接信息

**端口**: 443 (gateway/vic-gateway)  
**TLS**: 需要 `/run/vic-cloud/perRuntimeToken` 中存储的 JWT token  
**keepalive**: Time=30s, Timeout=10s

### 5.2 关键 RPC

| 服务                        | 方法                  | 用途               |
|-----------------------------|-----------------------|-------------------|
| ExternalAudioStreamPlayback | (双向流)              | PCM 音频播放        |
| PlayAnimation               | (unary)              | 动画播放           |
| SayText                      | (unary)              | 英文 TTS (内置)     |
| DriveWheels                 | (unary)              | 轮子控制           |
| BehaviorControl             | (双向流)              | 行为控制 (**不可用**) |

> **BehaviorControl**: proto 定义在 `robot-mcp/proto/robot.proto`，但本版 Gateway 不支持，调用会 crash (SIGABRT)。

### 5.3 Proto 目录

| 文件                                | 来源                        | 内容                             |
|--------------------------------------|-----------------------------|----------------------------------|
| `robot-mcp/proto/robot.proto`       | 自建                       | ExternalAudio + BehaviorControl  |
| `anki/victor/tools/protobuf/gateway/` | Anki 官方                   | 完整 gateway API                 |
| `anki/victor/proto/`                | Anki 官方                   | 底层消息和状态                   |

---

## 6. LLM 配置

### 6.1 Provider 配置

**位置**: `daima-agent/spiffs_data/config/config.json`

```json
{
  "active_provider": "deepseek",
  "providers": {
    "deepseek": {
      "openai_base_url": "https://api.deepseek.com/v1",
      "model": "deepseek-v4-pro",
      "context_limit_tokens": 128000
    },
    "kimi": { ... },
    "bigmodel": { ... }
  }
}
```

### 6.2 voice 通道 LLM 限制

**位置**: `daima-agent/main/agent/agent_turn_prepare.c`

"回答控制在 1-2 句"，由 LLM 自行遵守（不强制截断）。

---

## 7. 关键路径速查

| 想了解...                              | 看这里                                                  |
|----------------------------------------|---------------------------------------------------------|
| CLAD 消息定义                          | `anki/victor/robot/clad/src/clad/robotInterface/`       |
| 4 麦波束成形原理                       | `anki/victor/3rd/signalEssence/v009/vicos/project/anki_victor/policy_actions.c` |
| mic_sock 消息处理                      | `robot-mcp/audio.go`                                    |
| PCM 播放 socket 协议                    | `robot-mcp/audio_socket.go`                             |
| gRPC 连接与认证                        | `robot-mcp/robot.go`                                    |
| TTS 调用                               | `daima-agent/main/voice/voice_channel.c`                |
| 分句 + 增益 + 低通                     | `daima-agent/main/voice/tts_player.c`                   |
| 中文 UTF-8 修复                        | `daima-agent/main/agent/context_builder.c`              |
| VAD + 录音 + ASR 管线                  | `daima-agent/main/channels/vector/vector_channel.c`     |
| MCP 客户端 (dauma ↔ robot-mcp)         | `daima-agent/main/channels/vector/mcp_client.c`         |
| 播放中断机制                           | `robot-mcp/robot.go` → `/tmp/daima_playback_cancel`    |
| Gateway API proto                      | `anki/victor/tools/protobuf/gateway/public/messages.proto` |

---

## 8. 知识溯源方法

在探索过程中，按以下顺序逐步建立对协议栈的理解：

1. **从行为反查**: 看到 `audio.go` 处理 tag=1,2,3 字节协议 → 找定义 → 定位到 `.clad` 文件
2. **从常量追踪**: `kNumInputChannels=4` → 搜索引用 → 定位到 Signal Essence 的波束成形实现
3. **从 proto 找接口**: protobuf `.proto` 文件定义 gRPC 接口和消息格式
4. **从注释推意图**: Anki 工程师在 policy_actions.c 中留下了详细的波束算法说明
5. **从命名惯例**: CLAD tag 值 (0xDA, 0xD9) 看 Union 定义确认消息类型
6. **看引用关系**: `MicDirectionHistory` 被哪些 behavior 使用 → 理解方向数据在引擎层的用途
