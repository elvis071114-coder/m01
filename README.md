# M-01 Companion

**中文** ｜ [English](#english)

有長期記憶的 AI 聊天夥伴。她會記得你說過的話和傳過的檔案，會自己記下關於你的重點，也會在之後主動關心你提過的事。

## 怎麼用

- **網頁版**：https://elvis071114-coder.github.io/m01/
  - 用你自己的**免費 Gemini 金鑰**（到 [aistudio.google.com/apikey](https://aistudio.google.com/apikey) 用 Google 帳號建立）。
  - 第一次打開要先用 **Google 帳號登入**，記憶會存在你的瀏覽器，並另外存一份到你自己 Google 雲端硬碟的隱藏資料夾，換手機、換電腦登入同一個帳號就能接著聊。
  - 手機可以把網頁「加到主畫面」，像 App 一樣打開。
- **電腦版 App（Mac／Windows）**：在網頁版的「下載 App」分頁下載。
  - 第一次打開要先用 Google 登入，再設定至少一個 AI：免費的 Gemini、免費的本地 AI（Ollama，不用網路），或 Claude。
  - 本地 AI 的模型可以背景下載，能暫停、繼續，會顯示還要多久；沒有 NVIDIA 顯示卡的電腦建議用 Gemini 或輕量版。
  - 會上網查資料、查天氣，可以用 Fish Audio 把回覆唸出來，記憶存在電腦裡的資料夾。
  - 有新版本時會自動提醒。

## 角色圖

角色的樣子是你自己決定的：到「設定 → CHARACTER SPRITES」放圖片就好，也可以直接把圖片拖到格子上。

- **最少兩張**：「張眼（平常）」和「張嘴」。說話時兩張會交替，做出對嘴的效果。
- 其他表情都是選填，沒放的會用平常的圖代替。
- 建議用**去背 PNG**，每張的**尺寸一樣、角色位置一樣**，切換時才不會跳動。
- 可以**一次選好幾張，或直接選 zip**：檔名有表情名稱（例如下表的建議檔名，或「開心」「害羞」這種中文）就會自動放到對的格子。
- 請用**你自己畫的**，或**作者同意你使用**的圖片。

### 範例角色

還沒有自己的角色圖，可以先用附的範例角色（12 種表情，在 [`character/`](character/) 資料夾）：

- **網頁版**：到「設定 → CHARACTER SPRITES」按 **套用範例角色**，一鍵放好。
- **電腦版**：到「設定 → CHARACTER SPRITES」按 **套用範例角色**（要連網路）。也可以在網頁版的「下載 App」分頁下載範例角色圖（zip），再用「一次放多張圖片或 zip」直接選這個 zip。

角色靈感來自社群的 **Claude娘** 二創形象，圖片是為這個 App 用 AI 製作的。

| 格子 | 建議檔名 | 用途 |
|---|---|---|
| 張眼（平常） | Eyes_open.png | 必填，平常的樣子 |
| 閉眼 | Eyes_closed.png | 眨眼 |
| 張嘴 | Mouth_open.png | 說話對嘴 |
| 開心 | Happy.png | 選填 |
| 害羞 | Shy.png | 選填 |
| 生氣 | Angry.png | 選填 |
| 得意 | Smug.png | 選填 |
| 思考 | Thinking.png | 選填 |
| 驚訝 | Surprised.png | 選填 |
| 擔心 | Worried.png | 選填 |
| 難過 | Sad.png | 選填 |
| 睡著 | Asleep.png | 選填（10 分鐘沒動會睡著） |

## 注意事項

- 她的回答是 AI 產生的，可能會出錯；健康、金錢、法律這類重要的事請自己再確認。
- 你的金鑰只存在你自己的瀏覽器或電腦裡，不會傳給我們。
- 這是正式版 1.0，之後會持續更新，版本號規則見下方。

---

<a id="english"></a>
# M-01 Companion (English)

An AI companion with long-term memory. She remembers what you've said and the files you've shared, saves key points about you on her own, and checks in later about things you mentioned.

## How to use

- **Web version**: https://elvis071114-coder.github.io/m01/
  - Uses your own **free Gemini key** (create one at [aistudio.google.com/apikey](https://aistudio.google.com/apikey) with a Google account).
  - On first launch you **sign in with Google**. Memory is stored in your browser, with a copy in a hidden folder of your own Google Drive, so you can pick up on any phone or computer.
  - On phones, “Add to Home Screen” to open it like an app.
- **Desktop app (Mac / Windows)**: download it from the “Get App” tab of the web version.
  - On first launch you sign in with Google, then set up at least one AI: free Gemini, the free local AI (Ollama, works offline), or Claude.
  - Local models download in the background, with pause, continue and time left. On computers without an NVIDIA graphics card, Gemini or the Light model is recommended.
  - Looks things up on the web, checks the weather, can read replies aloud with Fish Audio, and saves memory to a folder on your computer.
  - Tells you when a new version is out.

## Character images

You decide what she looks like: add images in Settings → CHARACTER SPRITES, or drag pictures straight onto the slots.

- **At least two**: “Eyes open (neutral)” and “Mouth open”. They alternate while she talks to lip-sync.
- Every other expression is optional; missing ones fall back to the neutral image.
- Use **transparent PNGs**, all the **same size with the character in the same spot**, so switching doesn't jump.
- You can **pick many pictures at once, or a zip**: files named after an expression (like the suggested names below) go into the right slot automatically.
- Please use art **you made yourself** or that **the artist has allowed you to use**.

### Sample character

No pictures yet? Use the included sample character (12 expressions, in the [`character/`](character/) folder):

- **Web version**: Settings → CHARACTER SPRITES → **Use the sample character**, done in one click.
- **Desktop app**: Settings → CHARACTER SPRITES → **Use the sample character** (needs internet). Or download the sample character zip from the “Get App” tab of the web version and pick it with “Add many pictures or a zip”.

The character concept is inspired by the community’s **“Claude-chan”** fan personification; the images were made with AI for this app.

| Slot | Suggested file name | Used for |
|---|---|---|
| Eyes open (neutral) | Eyes_open.png | Required, the default look |
| Eyes closed | Eyes_closed.png | Blinking |
| Mouth open | Mouth_open.png | Lip-sync while talking |
| Happy | Happy.png | Optional |
| Shy | Shy.png | Optional |
| Angry | Angry.png | Optional |
| Smug | Smug.png | Optional |
| Thinking | Thinking.png | Optional |
| Surprised | Surprised.png | Optional |
| Worried | Worried.png | Optional |
| Sad | Sad.png | Optional |
| Asleep | Asleep.png | Optional (she dozes off after 10 quiet minutes) |

## Notes

- Her answers are AI-generated and can be wrong. Double-check anything important (health, money, legal).
- Your keys stay in your own browser or computer and are never sent to us.
- Version 1.0 — updates keep coming; see the versioning rules below.


隱私權政策 Privacy Policy: https://elvis071114-coder.github.io/m01/privacy.html

## 版本號規則 / Versioning

版本號是 `主版本.功能版本.修正版本`（例如 1.2.3）：

- **修正版本**（1.0.**1**）：修 bug、小調整，不加新功能。App 裡一鍵更新就好。
- **功能版本**（1.**1**.0）：新功能或明顯的改進。如果需要重新安裝電腦端程式，一定會升這一碼，並在更新說明寫清楚。
- **主版本**（**2**.0.0）：大改版或不相容的變動，例如資料格式改變、所有人都要重新安裝。

Version numbers are `major.minor.patch`. Patch (1.0.**1**): bug fixes only, one-click update. Minor (1.**1**.0): new features or clear improvements — any release that needs the desktop helper reinstalled is at least a minor bump and says so. Major (**2**.0.0): big redesigns or incompatible changes (new data format, everyone reinstalls).
