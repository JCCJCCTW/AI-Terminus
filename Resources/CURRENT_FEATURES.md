# AI Terminus 目前主要功能

## 產品定位

AI Terminus 是一個 macOS SSH 終端機工具，整合多 Session 管理、主機清單管理，以及可直接結合遠端終端機操作的 AI 助理。

## 主要功能

### 1. SSH 主機管理

- 新增、編輯、刪除、複製 SSH 主機
- 支援名稱、主機位址、連接埠、使用者名稱、群組、備註
- 支援密碼與私鑰兩種認證方式
- 可從檔案選擇 SSH 私鑰路徑
- 主機可依群組整理與折疊顯示
- 可用搜尋快速篩選主機

### 2. 多 Session 終端機

- 可同時開啟多個 SSH Session
- Session 會依數量自動切換版面：
  - 1 個 Session：單一全區顯示
  - 2 個 Session：左右分割
  - 3 個 Session：上下堆疊
  - 4 個 Session：2 x 2
  - 5 個以上：3 x 3 九宮格並支援分頁
- 支援拖曳調整 Session 順序
- 支援關閉目前 Session
- Session 切頁或切換版面時，連線會持續保留

### 3. 原生終端機操作體驗

- 使用 SwiftTerm 提供 SSH 終端機顯示與輸入
- 讓鍵盤事件直接送進目前聚焦的 terminal
- 支援一般 shell 輸入、方向鍵、Ctrl 類控制鍵等操作
- 點擊 terminal 即可切換焦點到對應 Session

### 4. AI 助理面板

- 右側可開啟或隱藏 AI 助理面板
- 支援多家模型提供者：
  - Anthropic / Claude
  - OpenAI / ChatGPT
  - Google Gemini
  - Ollama（本機）
- 可選擇目前要分析或控制的 Session
- AI 可根據當前 Session transcript 提供分析、建議與指令說明
- 在明確指定控制指令時，可直接把命令或控制鍵送到 Session
- AI 面板若發生子系統錯誤，可隔離並重新載入，不影響既有 SSH Session

### 5. AI 輸入輔助

- 支援在 AI 輸入框中使用 Session mention
- 支援 slash command 形式的控制指令
- 可依輸入內容顯示補全選項
- 可在分析模式與實際操作模式間區分行為

### 6. 設定與語言

- 可設定 AI Provider、API Key、模型名稱或本機服務位址
- 支援繁體中文與 English 介面語言
- 語言與 AI 設定透過設定面板集中管理
- 語言切換需按下儲存後才會正式套用

### 7. macOS 整合

- 提供選單列指令與快捷鍵
- 支援顯示 / 隱藏 AI 面板
- 支援上一頁 / 下一頁 Session 分頁切換
- 支援關閉目前 Session
- 可打包成 macOS `.app` 執行

## 目前適用情境

- 管理多台 Linux / Unix 主機
- 同時監看多個 SSH 工作階段
- 請 AI 協助分析遠端主機狀態或產生操作指令
- 在同一個工具內完成主機管理、連線與 AI 協作
