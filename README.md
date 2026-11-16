# PhotoBridge 照片備份

iPhone → Windows 免費照片備份。同一個 Wi-Fi 直接傳，不經雲端。只讀取照片，不刪除、不修改手機或 iCloud 上的任何東西。

- `windows/`：接收端（Node.js，零設定，瀏覽器操作介面）
- `ios/`：iPhone App（SwiftUI + PhotoKit）

## 下載

- **Windows 接收程式**：[PhotoBridge-Windows.zip](https://github.com/Charonyuu/photo-bridge/releases/latest/download/PhotoBridge-Windows.zip)（解壓後雙擊 `PhotoBridge.exe`，不用裝 Node）
- **iPhone App**：TestFlight <https://testflight.apple.com/join/RXRkM2PW>

## 使用

1. Windows：雙擊 `PhotoBridge.exe`（不用裝 Node），瀏覽器會打開 `http://localhost:52765`。
   - 出現「Windows 已保護您的電腦」：按「其他資訊 → 仍要執行」（exe 沒有程式碼簽章）。
   - 防火牆詢問：允許「私人網路」，手機才連得進來。
   - 開發時也可以裝 Node.js 後雙擊 `windows/start.bat`。
2. 選備份資料夾。
3. iPhone 從 TestFlight 安裝「照片備份」（不用開開發者模式），打開，掃畫面上的 QR Code（用系統相機掃也可以），按「開始備份」。
4. 完成後看「已備份 / 失敗 / 只在 iCloud / 尚未備份」。再按一次「重新檢查並補傳」只會傳缺的。

## 怎麼保證完整

| 環節 | 做法 |
|---|---|
| 讀取 | `PHAssetResourceManager.requestData` 串流讀原始檔，同時算 SHA-256；不轉檔、不壓縮 |
| 傳輸 | `PUT /api/upload`，header 帶 SHA-256 與大小 |
| 收檔 | 先寫 `.part`、邊收邊算 SHA-256、`fsync`；大小和雜湊都跟手機一致才改名成正式檔並寫進索引 |
| 去重 / 續傳 | 索引 `<備份資料夾>/.photobridge/index.jsonl`（append-only）。每批 200 項先 `POST /api/check`，已驗證的略過 |
| 事後驗證 | 電腦端「重新驗證所有檔案」重讀每個檔算 SHA-256，不見或損毀的從索引移除，下次自動補傳 |
| 計數 | 以「照片／影片項目」為單位：所有原始檔都驗證過才算已備份 |

### 備份哪些檔
原始照片、影片、Live Photo 的影片、RAW+JPEG 的另一個檔、音訊，以及編輯過的版本（存成 `IMG_0001_edited.jpg`）。隱藏相簿、連拍每一張都包含。
電腦上依拍攝年月放：`2024/2024-05/IMG_0001.HEIC`，檔案修改時間設成拍攝時間。撞名加 `(2)`。

### iCloud 最佳化儲存空間
這版 `isNetworkAccessAllowed = false`，不下載 iCloud。手機上沒有原始檔的項目標成「只在 iCloud」，不算成功，清單寫在手機 App 和電腦備份資料夾的 `未完成備份清單.csv`。

### 唯讀
整個 App 沒有呼叫 `PHPhotoLibrary.performChanges`。要讀完整圖庫，iOS 只提供 readWrite 權限等級可選，App 本身不寫。
檢查：`grep -rn performChanges ios/` 應該沒有結果。

## 開發

```bash
cd windows && npm install && npm test
```

```bash
cd ios && xcodegen generate && open PhotoBridge.xcodeproj
```

打包 exe（在 Windows 上，需要 Node 25.5+）：`powershell -ExecutionPolicy Bypass -File windows/build-exe.ps1` → `windows/dist/PhotoBridge.exe`。

上傳 TestFlight：`xcodebuild archive -allowProvisioningUpdates` → `xcodebuild -exportArchive -exportOptionsPlist ios/ExportOptions.plist`（用 Xcode 登入的帳號，沙盒外跑）。App Store Connect App ID 6835513086，外部群組「PhotoBridge 公開測試」。

模擬器測試：`xcrun simctl openurl booted "<電腦端 /ui/pair-url 的網址>"` 配對。

## 已知限制（v0.1）

- 續傳以「檔案」為單位：一支大影片傳到一半斷線會整支重傳。
- 手機要先把原始檔暫存一份再上傳，手機空間極少時大影片可能失敗（會標「失敗」並寫原因）。
- App 要保持在前景；切到背景約 30 秒後停止，下次補傳。
- 區網用 HTTP + 配對 token，未加密。
- 電腦端資料夾挑選視窗用 PowerShell，只在 Windows / macOS 有；其他系統手動貼路徑。
