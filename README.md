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

預設會用你目前機器的原生架構編譯。指定其他架構：

```bash
./scripts/build-app.sh arm64      # Apple Silicon 明確指定
./scripts/build-app.sh x86_64     # Intel
./scripts/build-app.sh universal  # arm64 + x86_64（Xcode 26 需要另外下載 Metal Toolchain）
```

> **注意**：Xcode 26 的 `xcodebuild` 多架構路徑目前對新下載的 Metal Toolchain 會辨識失敗（SwiftTerm 內含 `.metal` shader），所以預設走單一架構的 `swift build`。要打 universal 請先執行 `xcodebuild -downloadComponent MetalToolchain` 並確認 `xcrun -f metal` 找得到工具。

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

## 目前主要功能說明

### 1. SSH 主機管理

- 新增、編輯、刪除、複製 SSH 主機
- 支援名稱、主機位址、連接埠、使用者名稱、群組、備註
- 支援密碼與私鑰兩種認證方式
- 可從檔案選擇 SSH 私鑰路徑
- 主機可依群組整理、折疊與搜尋

### 2. 多 Session 終端機

- 可同時開啟多個 SSH Session
- Session 版面會依數量自動切換
- 支援拖曳調整 Session 順序
- 支援 Session 分頁切換
- 切頁或切換版面時，既有 SSH 連線會持續保留

### 3. 原生終端機操作

- 使用 SwiftTerm 顯示與輸入終端內容
- 鍵盤事件會路由到目前聚焦的 terminal
- 支援一般 shell 操作、方向鍵與 Ctrl 類控制鍵
- 點擊 terminal 即可切換對應 Session 焦點

### 4. AI 助理面板

- 支援 Anthropic / Claude、OpenAI / ChatGPT、Google Gemini、Ollama
- 可選擇目前要分析或控制的 Session
- 可根據 Session transcript 提供分析、建議與指令說明
- 明確指定控制指令時，可直接送命令或控制鍵到 Session
- AI 子系統錯誤時可隔離並重新載入，不影響 SSH Session

### 5. AI 輸入輔助

- 支援 Session mention
- 支援 slash command
- 支援輸入補全
- 區分分析模式與實際操作模式

### 6. 設定與語言

- 可設定 AI Provider、API Key、模型名稱或本機服務位址
- 支援繁體中文與 English
- 語言切換需按下儲存後才會正式套用

### 7. macOS 整合

- 提供選單列指令與快捷鍵
- 支援顯示 / 隱藏 AI 面板
- 支援上一頁 / 下一頁 Session 分頁
- 支援關閉目前 Session
- 可打包成 macOS `.app` 執行

## 授權

MIT
