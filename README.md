# AI Terminus

macOS SSH 終端機工具，內建 AI 助理（Claude / ChatGPT / Gemini / Ollama），支援多 Session 九宮格排版與主機群組管理。

## 功能

- **左側主機清單**：分群組折疊、搜尋、雙擊連線、右鍵選單（連線 / 重新命名 / 複製 / 內容 / 刪除）
- **中央 Session 區**：動態排版
  - 1 個：全螢幕
  - 2 個：左右分割
  - 3 個：上中下
  - 4 個：2×2
  - 5+ 個：3×3 九宮格，分頁切換（⌘⇧← / ⌘⇧→）
- **右側 AI 助理**：多家 Provider、Session 選擇器、一鍵發送指令到終端機（⌘⇧A 切換）
- **鍵盤路由**：Ctrl+C、方向鍵、Vim 快捷鍵等原生鍵盤事件可直達 SSH PTY
- **Session 永續**：切換分頁時 SSH 連線保持不中斷

## 需求

- macOS 13 (Ventura) 以上
- Xcode 15+ 或 Swift 5.9 toolchain
- 系統已安裝 `/usr/bin/ssh`（macOS 內建）

## 從原始碼建置

### 以 Xcode 開發

```bash
open Package.swift
```

在 Xcode 中按 ⌘R 執行。

### 以命令列打包成 .app

```bash
./scripts/build-app.sh
open "dist/AI Terminus.app"
```

指定架構：

```bash
./scripts/build-app.sh arm64      # Apple Silicon
./scripts/build-app.sh x86_64     # Intel
./scripts/build-app.sh            # universal
```

要安裝到 `/Applications`：

```bash
cp -R "dist/AI Terminus.app" /Applications/
```

## AI 設定

啟動後點右上角 ✨ 按鈕（或按 ⌘⇧A）開啟 AI 面板，點齒輪設定：

| Provider | 需要 | 說明 |
|----------|------|------|
| Anthropic / Claude | API Key (`sk-ant-...`) | console.anthropic.com |
| OpenAI / ChatGPT | API Key (`sk-...`) | platform.openai.com |
| Google Gemini | API Key (`AIza...`) | aistudio.google.com |
| Ollama（本機） | 服務位址 + 模型 | 預設 `http://localhost:11434` |

API Key 儲存在本機 `UserDefaults`，不上傳任何地方。

## 技術架構

- **SwiftUI + AppKit Interop** — `NSViewRepresentable` 包裝 SwiftTerm 的 `LocalProcessTerminalView`
- **SwiftTerm 1.13** — PTY 終端機模擬
- **NSEvent local monitor** — 繞過 SwiftUI `NSHostingView` 攔截，將鍵盤事件正確路由到終端機
- **Session 生命週期** — `SSHSession` 強參考 `LocalProcessTerminalView`，確保分頁切換時 SSH 連線不中斷

## 授權

MIT
