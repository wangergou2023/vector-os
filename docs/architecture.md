# Daima + Vector 系统架构

## 组件

| 仓库 | 语言 | 部署路径 | 说明 |
|------|------|---------|------|
| [daima-agent](https://github.com/wangergou2023/daima-agent) | C | `/data/daima/bin/daima` | AI Agent 主进程 |
| [vector-mcp](https://github.com/wangergou2023/vector-mcp) | Go | `/anki/bin/vic-cloud` (gateway) + `/data/daima/bin/robot-mcp` (client) | 同二进制双模式 |

## 进程关系

```
systemd
  ├── vic-cloud (Gateway mode, :443)
  │     ├── gRPC server (ExternalInterface)
  │     ├── engineProtoManager IPC → vic-engine
  │     └── engineCladManager IPC  → vic-engine
  │
  └── daima (popen → robot-mcp --client-only)
        │
        ├── stdin/stdout (MCP JSON‑RPC)
        │     ├── subscribe/unsubscribe audio
        │     ├── 19 robot control tools
        │     └── notifications/audio/chunk
        │
        ├── Unix socket (/tmp/daima_spk.sock)
        │     └── PCM playback (seq + text + pcm)
        │
        ├── BigModel API (ASR/TTS)
        │     └── 中文语音识别 + 合成
        │
        └── DeepSeek v4-pro API
              └── LLM reasoning + tool calling
```

## 数据流

```
用户说话
  → Vector 麦克风
  → vic-engine → mic_sock
  → robot-mcp audio subscriber
  → daima VAD + PCM buffer
  → BigModel ASR → 中文文本
  → Agent context builder (方向 + 传感器注入)
  → DeepSeek LLM (tool calling)
  → Agent tool executor
  → robot-mcp MCP tools/call
  → vic-cloud gRPC → engine 执行
  → LLM 生成回复文本
  → BigModel TTS → PCM (24000→16000Hz)
  → daima tts_player (分句 + 发送)
  → robot-mcp Unix socket → spkPlay
  → Vector 扬声器
```

## BehaviorControl

每个 motor 命令内部自动走 BehaviorControl：

```
handleDriveStraight()
  → StartForegroundActivity()    // ControlRequest → ControlGranted
  → DriveWheels(v, v)            // 引擎执行
  → time.Sleep(duration)
  → DriveWheels(0, 0)           // 停止
  → StopForegroundActivity()     // ControlRelease
```

AppIntent 走 clad 通道（`engineCladManager.Write`），不经过 BehaviorControl 检查。

## 工具集

19 个 MCP 工具：

| 分类 | 工具 | 通道 |
|------|------|------|
| 运动 | `drive_straight` `turn_in_place` `drive_wheels` `stop` | BC + fire-and-forget proto |
| 头/臂 | `set_head_angle` `set_lift_height` | BC + clad |
| 动画 | `play_animation` | BC + proto (PlayAnimation) |
| 行为 | `app_intent` | clad (AppIntent) |
| 充电 | `drive_on_charger` `drive_off_charger` | clad / BC+timed |
| 电源 | `get_battery` | proto (engine responds) |
| 传感器 | `get_sensors` `mic_get_direction` | EventStream / audio notification |
| 音频 | `set_volume` `play_pcm` `cancel_playback` | proto / Unix socket |
| 系统 | `subscribe_audio` `unsubscribe_audio` `activity_start` `activity_end` | internal |

## 关键修复历史

- **BehaviorControl BC 上下文**：`defer cancel()` 提前杀 BC 流 → 改为手动管理
- **MCP 响应丢失**：音频通知占用 stdout → `call_tool` 循环读行 + `pending` buffer
- **动画播放**：`PlayAnimationTrigger` 触发器名引擎不理 → 改用 `PlayAnimation` 直传引擎文件名
- **C use-after-free**：`cJSON_Delete(in)` 在 `snprintf(name)` 之前 → 交换顺序
- **AppIntent cooldown**：连续 intent 堵塞 clad 通道 → 1.5s 节流
- **transport flush**：`json.Encoder` buffer 不 flush → 加 `stdout.Sync()`
