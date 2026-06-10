// ZhLearnHook：vChewing 上屏漢字 → 翻成英文 + 學習說明 → 原生 NSPanel 浮窗。
// 浮窗：半透明、可拖曳、可改大小、扁平風格按鈕、⚙設定(右下)、✕關閉(右上)、token/花費(左下)、譯文垂直置中靠左。
import AppKit
import ApplicationServices
@preconcurrency import AVFoundation
import Carbon
import Foundation

public enum ZhLearnHook {
  private static var buffer = ""
  private static var resetNext = false
  private static var lastCommit = Date(timeIntervalSince1970: 0)
  private static var lastCaret = NSPoint.zero
  private static var lastText = ""
  private static var work: DispatchWorkItem?
  private static var reqSeq = 0
  private static var sentenceHistory: [String] = []  // 精準模式用：最近完成的句子（最多 5）
  static var userClosed = false

  private static var observerSet = false

  /// 註冊英文側錄通知（InputHandler 在 ASCII 模式發出，因英文不經 commit）。
  static func setupObserver() {
    if observerSet { return }
    observerSet = true
    NotificationCenter.default.addObserver(
      forName: .init("ZhLearnEnglishChar"), object: nil, queue: .main
    ) { note in
      if let s = note.object as? String { accumulate(s, caret: lastCaret) }
    }
    reRegisterHotkey()
  }

  /// 依設定（重新）註冊反白翻譯熱鍵。
  static func reRegisterHotkey() {
    let c = ZhLearnConfig.load()
    HotkeyManager.shared.register(keyCode: c.hotkeyKeyCode, mods: c.hotkeyMods)
  }

  /// 熱鍵觸發：讀取目前選取文字 → 自動判中/英 → 翻譯/解析。
  static func hotkeyFired() {
    if !AXIsProcessTrusted() {
      let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
      _ = AXIsProcessTrustedWithOptions(opts)
      userClosed = false
      ZhLearnPanel.shared.show(
        "需要「輔助使用」權限：系統設定 → 隱私權與安全性 → 輔助使用 → 開啟 vChewing，再按一次熱鍵",
        notes: "", cost: "", at: .zero)
      return
    }
    guard let sel = readSelectedText()?.trimmingCharacters(in: .whitespacesAndNewlines),
      !sel.isEmpty
    else {
      userClosed = false
      ZhLearnPanel.shared.show("（沒讀到選取文字；Office 無法讀取選取）", notes: "", cost: "", at: .zero)
      return
    }
    analyzeText(sel)
  }

  /// 分析任意文字（反白選取 / 貼上 / 輸入框）：自動判中英 → 翻譯或改寫+建議。
  static func analyzeText(_ text: String) {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return }
    userClosed = false
    let hasCJK = t.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
    let englishMode = !hasCJK
    reqSeq += 1
    let seq = reqSeq
    ZhLearnPanel.shared.show(englishMode ? "分析中…" : "翻譯中…", notes: "", cost: "", at: .zero)
    let cfg = ZhLearnConfig.load()
    ZhLearnTranslator.translate(
      t, englishMode: englishMode, precise: cfg.preciseMode, domain: cfg.domain, history: [],
      onChunk: { partial in
        DispatchQueue.main.async {
          guard seq == reqSeq else { return }
          ZhLearnPanel.shared.streamUpdate(partial)
        }
      },
      onDone: { main, notes, cost in
        DispatchQueue.main.async {
          guard seq == reqSeq else { return }
          ZhLearnPanel.shared.show(main, notes: notes, cost: cost, at: .zero)
        }
      })
  }

  private static func readSelectedText() -> String? {
    let sys = AXUIElementCreateSystemWide()
    var focused: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused)
        == .success, let elem = focused, CFGetTypeID(elem) == AXUIElementGetTypeID()
    else { return nil }
    let el = elem as! AXUIElement
    var sel: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &sel) == .success
    else { return nil }
    return sel as? String
  }

  public static func onCommit(_ text: String, caret: NSPoint) {
    setupObserver()
    accumulate(text, caret: caret)
  }

  private static func accumulate(_ text: String, caret: NSPoint) {
    DispatchQueue.main.async {
      let cfg = ZhLearnConfig.load()
      guard cfg.liveEnabled else { return }  // 即時翻譯關閉 → 打字不彈窗（反白熱鍵不受影響）
      let now = Date()
      let threshold = cfg.resetSec
      if resetNext || now.timeIntervalSince(lastCommit) > threshold {
        if !buffer.isEmpty {  // 完成的句子推入歷史（精準模式當前文）
          sentenceHistory.append(buffer)
          if sentenceHistory.count > 5 { sentenceHistory.removeFirst() }
        }
        buffer = ""
        resetNext = false
      }
      lastCommit = now
      buffer += text
      lastCaret = caret
      // 只認中文句尾標點與換行（避免英文 . ! ? 誤觸而清掉前面中文）
      if let last = text.unicodeScalars.last, "。！？\n".unicodeScalars.contains(last) {
        resetNext = true
      }
      if buffer.count > 120 { resetNext = true }
      let snap = buffer
      let caretSnap = lastCaret
      work?.cancel()
      let w = DispatchWorkItem { translateAndShow(snap, caret: caretSnap) }
      work = w
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }
  }

  static func imeActivated() {
    // 只解除使用者關閉；不清空累積（切英文模式也會觸發 activateServer，
    // 若在此清空會把前面中文丟掉導致「打英文就中斷」）。新句改由重置秒數判斷。
    userClosed = false
    setupObserver()
  }

  static func retranslateLast() {
    guard !lastText.isEmpty else { return }
    translateAndShow(lastText, caret: lastCaret)
  }

  // 給 SessionCtl 選單 action 呼叫（ZhLearnConfig 為本檔 private）。
  static func menuToggleLive() {
    let now = !ZhLearnConfig.load().liveEnabled
    ZhLearnConfig.write(["liveEnabled": now])
    if !now { ZhLearnPanel.shared.hide() }  // 關掉即時翻譯 → 同步收起浮窗
  }
  static func hidePanelIfLiveOff() {
    if !ZhLearnConfig.load().liveEnabled { ZhLearnPanel.shared.hide() }
  }
  static func menuSetStyle(_ key: String) {
    ZhLearnConfig.write(["style": key])
  }
  static func liveEnabledNow() -> Bool { ZhLearnConfig.load().liveEnabled }
  static func currentStyle() -> String { ZhLearnConfig.load().style }
  static func resetCost() {
    CostTracker.reset()
    ZhLearnPanel.shared.refreshCost()
  }

  private static func translateAndShow(_ text: String, caret: NSPoint) {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasCJK = t.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
    let hasLatin = t.unicodeScalars.contains {
      ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122)
    }
    guard hasCJK || (hasLatin && t.count >= 2) else { return }
    let englishMode = !hasCJK  // 純英文 → 英文寫作助理模式
    if englishMode, !ZhLearnConfig.load().englishAssist { return }  // 助理可在設定關閉
    if userClosed { return }
    lastText = t
    reqSeq += 1
    let seq = reqSeq
    ZhLearnPanel.shared.show(englishMode ? "分析中…" : "翻譯中…", notes: "", cost: "", at: caret)
    let cfg = ZhLearnConfig.load()
    ZhLearnTranslator.translate(
      t, englishMode: englishMode, precise: cfg.preciseMode, domain: cfg.domain,
      history: sentenceHistory,
      onChunk: { partial in
        DispatchQueue.main.async {
          guard seq == reqSeq, !userClosed else { return }
          ZhLearnPanel.shared.streamUpdate(partial)
        }
      },
      onDone: { main, notes, cost in
        DispatchQueue.main.async {
          guard seq == reqSeq, !userClosed else { return }
          ZhLearnPanel.shared.show(main, notes: notes, cost: cost, at: caret)
        }
      })
  }
}

private struct ZhLearnConfig {
  var apiKey = ""
  var model = "gpt-4o-mini"
  var provider = "openai"
  var baseURL = ""
  var style = "business"
  var resetSec = 2.0
  var englishAssist = true
  var opacity = 0.96
  var liveEnabled = true  // 打字即時翻譯總開關
  var preciseMode = false  // 精準翻譯：理解整句＋前文＋修正口語斷句
  var domain = ""  // 用字領域（如 醫學/法律/軟體）
  var hotkeyKeyCode = 17  // T
  var hotkeyMods = cmdKey | optionKey  // ⌘⌥
  var hotkeyLabel = "⌥⌘T"
  // 朗讀引擎：apple＝系統內建（離線零設定）；endpoint＝OpenAI 相容 TTS（如本機 Kokoro-FastAPI）。
  var ttsEngine = "apple"
  var ttsEndpoint = "http://localhost:8880/v1/audio/speech"
  var ttsVoice = "af_heart"
  var ttsApiKey = ""  // 雲端 TTS 才需要；本機 Kokoro 留空
  var ttsPiperVoice = "en_US-amy-medium"  // 內建 Piper 引擎要用的語音
  var ttsSpeed = 1.0  // 朗讀語速倍率（1.0＝正常；>1 較快）
  /// 自動補正 TTS 端點路徑（填基底 / .../v1 / 完整路徑都接成 .../v1/audio/speech）。
  var ttsURL: String {
    var u = ttsEndpoint.trimmingCharacters(in: .whitespaces)
    while u.hasSuffix("/") { u.removeLast() }
    if u.isEmpty { return "http://localhost:8880/v1/audio/speech" }
    if u.hasSuffix("/audio/speech") { return u }
    if u.hasSuffix("/v1") { return u + "/audio/speech" }
    return u + "/v1/audio/speech"
  }
  var endpoint: String {
    if !baseURL.isEmpty {
      // 自動補正路徑：不論填基底 / .../v1 / 完整路徑，都接成正確的 chat completions 端點
      var u = baseURL.trimmingCharacters(in: .whitespaces)
      while u.hasSuffix("/") { u.removeLast() }
      if u.hasSuffix("/completions") { return u }
      if u.hasSuffix("/v1") { return u + "/chat/completions" }
      return u + "/v1/chat/completions"
    }
    switch provider {
    case "openrouter": return "https://openrouter.ai/api/v1/chat/completions"
    case "ollama": return "http://localhost:11434/v1/chat/completions"
    case "lmstudio": return "http://localhost:1234/v1/chat/completions"
    default: return "https://api.openai.com/v1/chat/completions"
    }
  }
  /// 地端/自架（不需 API Key、視為免費）。
  var isLocal: Bool {
    if provider == "ollama" || provider == "lmstudio" { return true }
    if !baseURL.isEmpty {
      let u = baseURL.lowercased()
      return u.contains("localhost") || u.contains("127.0.0.1") || u.contains("://192.168.")
        || u.contains("://10.") || u.contains(".local")
    }
    return false
  }
  static var path: String { ("~/.zhlearnime/config.json" as NSString).expandingTildeInPath }
  static func load() -> ZhLearnConfig {
    var c = ZhLearnConfig()
    guard let data = FileManager.default.contents(atPath: path),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return c }
    c.provider = obj["provider"] as? String ?? c.provider
    // 每個服務商各自一份 profile（apiKey/model/baseUrl）；無 profile 時回退舊的頂層欄位。
    let prof = (obj["profiles"] as? [String: Any])?[c.provider] as? [String: Any]
    c.apiKey = (prof?["apiKey"] as? String) ?? (obj["apiKey"] as? String) ?? ""
    c.model = (prof?["model"] as? String) ?? (obj["model"] as? String) ?? c.model
    c.baseURL = (prof?["baseUrl"] as? String) ?? (obj["baseUrl"] as? String) ?? ""
    c.style = obj["style"] as? String ?? c.style
    c.resetSec = (obj["resetSec"] as? NSNumber)?.doubleValue ?? c.resetSec
    c.englishAssist = (obj["englishAssist"] as? NSNumber)?.boolValue ?? c.englishAssist
    c.opacity = (obj["opacity"] as? NSNumber)?.doubleValue ?? c.opacity
    c.liveEnabled = (obj["liveEnabled"] as? NSNumber)?.boolValue ?? c.liveEnabled
    c.preciseMode = (obj["preciseMode"] as? NSNumber)?.boolValue ?? c.preciseMode
    c.domain = obj["domain"] as? String ?? c.domain
    c.hotkeyKeyCode = (obj["hotkeyKeyCode"] as? NSNumber)?.intValue ?? c.hotkeyKeyCode
    c.hotkeyMods = (obj["hotkeyMods"] as? NSNumber)?.intValue ?? c.hotkeyMods
    c.hotkeyLabel = obj["hotkeyLabel"] as? String ?? c.hotkeyLabel
    c.ttsEngine = obj["ttsEngine"] as? String ?? c.ttsEngine
    if let v = obj["ttsEndpoint"] as? String, !v.isEmpty { c.ttsEndpoint = v }
    if let v = obj["ttsVoice"] as? String, !v.isEmpty { c.ttsVoice = v }
    c.ttsApiKey = obj["ttsApiKey"] as? String ?? c.ttsApiKey
    if let v = obj["ttsPiperVoice"] as? String, !v.isEmpty { c.ttsPiperVoice = v }
    c.ttsSpeed = (obj["ttsSpeed"] as? NSNumber)?.doubleValue ?? c.ttsSpeed
    return c
  }
  static func rawProfiles() -> [String: [String: String]] {
    guard let data = FileManager.default.contents(atPath: path),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let p = obj["profiles"] as? [String: Any]
    else { return [:] }
    var out: [String: [String: String]] = [:]
    for (k, v) in p {
      if let d = v as? [String: Any] {
        out[k] = [
          "apiKey": d["apiKey"] as? String ?? "",
          "model": d["model"] as? String ?? "",
          "baseUrl": d["baseUrl"] as? String ?? "",
        ]
      }
    }
    return out
  }

  static func write(_ updates: [String: Any]) {
    var obj: [String: Any] = [:]
    if let data = FileManager.default.contents(atPath: path),
      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      obj = o
    }
    for (k, v) in updates { obj[k] = v }
    try? FileManager.default.createDirectory(
      at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
      try? data.write(to: URL(fileURLWithPath: path))
    }
  }
  static func setStyleQuick(_ style: String) { write(["style": style]) }
}

/// 累計 token 與花費（依模型費率，$ / 1M tokens）。
private enum CostTracker {
  static var sessionTokens = 0
  static var sessionCost = 0.0
  static func rates(_ model: String) -> (Double, Double) {
    let m = model.lowercased()
    if m.contains("gpt-4o-mini") { return (0.15, 0.60) }
    if m.contains("gpt-4.1-mini") { return (0.40, 1.60) }
    if m.contains("gpt-4.1-nano") { return (0.10, 0.40) }
    if m.contains("gpt-4.1") { return (2.0, 8.0) }
    if m.contains("gpt-4o") { return (2.5, 10.0) }
    return (0.15, 0.60)  // 預設 mini 費率
  }
  static func record(model: String, prompt: Int, completion: Int, free: Bool) -> String {
    let (inR, outR) = free ? (0, 0) : rates(model)
    let cost = Double(prompt) / 1_000_000 * inR + Double(completion) / 1_000_000 * outR
    sessionTokens += prompt + completion
    sessionCost += cost
    return summary()
  }
  static func summary() -> String {
    String(format: "累計 %d tok　$%.4f", sessionTokens, sessionCost)
  }
  static func reset() {
    sessionTokens = 0
    sessionCost = 0
  }
}

private enum ZhLearnTranslator {
  private static var current: Task<Void, Never>?

  static func translate(
    _ text: String, englishMode: Bool, precise: Bool, domain: String, history: [String],
    onChunk: @escaping (String) -> Void,
    onDone: @escaping (String, String, String) -> Void
  ) {
    current?.cancel()  // 取消前一個還在跑的請求（清掉地端 LLM 佇列，避免最新的排隊等很久）
    let cfg = ZhLearnConfig.load()
    if !cfg.isLocal, cfg.apiKey.isEmpty {
      onDone("（雲端服務需 API Key：按右下 ⚙ 設定）", "", "")
      return
    }
    guard let url = URL(string: cfg.endpoint) else {
      onDone("endpoint 錯誤（檢查 ⚙ 設定的 Base URL）", "", "")
      return
    }
    let register: String
    switch cfg.style {
    case "scientific": register = "a rigorous scientific/academic register: precise, formal"
    case "casual": register = "a relaxed, friendly, conversational register"
    default: register = "a professional business register: concise, polite"
    }
    var sys: String
    if englishMode {
      // 英文寫作助理：改寫英文 + 中文意思 + 多點錯字/用法建議
      sys =
        "You help a native Traditional-Chinese speaker improve their English writing. "
        + "The user wrote some English text. Use \(register).\n"
        + "Output a polished, corrected rewrite of the English first (fix typos, grammar, "
        + "word choice; make it natural and idiomatic). Then a line containing exactly ###. "
        + "Then, IN TRADITIONAL CHINESE (繁體中文):\n"
        + "a line `中文意思：<what it means>`,\n"
        + "then a line `建議：`,\n"
        + "then EACH suggestion on its OWN new line starting with 「・」, covering typos, grammar, "
        + "awkward usage, and better word choices — be thorough, give as many useful points as "
        + "apply, do not limit to one. Output nothing else."
    } else {
      sys =
        "You are a translation assistant helping a native Traditional-Chinese speaker write English.\n"
        + "Translate the user's Chinese into natural, idiomatic English using \(register).\n"
        + "Output the English translation first. Then a line containing exactly ###. "
        + "Then a brief note in Traditional Chinese (繁體中文) explaining a key word choice, tone, or "
        + "grammar point to help the learner, under 2 sentences. Output nothing else."
    }
    if precise {
      sys +=
        "\n\nPRECISE MODE: the user types via a Chinese IME one chunk at a time, so the input may be "
        + "mis-segmented, incomplete, or use colloquial/habitual phrasing. First infer the FULL intended "
        + "meaning of the whole sentence (use the prior context if provided) BEFORE translating; correct "
        + "any mis-segmentation or colloquialism so the output conveys the intended meaning naturally and "
        + "correctly — not a literal word-by-word rendering."
    }
    let dom = domain.trimmingCharacters(in: .whitespaces)
    if !dom.isEmpty {
      sys += "\n\nDomain/field: \(dom). Use vocabulary and terminology appropriate to this field."
    }
    var messages: [[String: String]] = [["role": "system", "content": sys]]
    if precise, !history.isEmpty {
      messages.append([
        "role": "system",
        "content":
          "Recent prior sentences from the user (context only; do NOT translate these, use only to understand):\n"
          + history.joined(separator: "\n"),
      ])
    }
    messages.append(["role": "user", "content": text])
    let body: [String: Any] = [
      "model": cfg.model, "temperature": 0.3, "messages": messages,
      "stream": true, "stream_options": ["include_usage": true],
    ]
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    if !cfg.apiKey.isEmpty {
      req.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization")
    }
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)

    let model = cfg.model
    let isLocal = cfg.isLocal
    current = Task {
      do {
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
          onDone("API 錯誤 \(http.statusCode)（檢查模型/服務是否啟動）", "", "")
          return
        }
        var acc = ""
        var pt = 0
        var ct = 0
        var lastSent = ""
        for try await line in bytes.lines {
          if Task.isCancelled { return }
          let l = line.trimmingCharacters(in: .whitespaces)
          guard l.hasPrefix("data:") else { continue }
          let payload = String(l.dropFirst(5)).trimmingCharacters(in: .whitespaces)
          if payload == "[DONE]" { break }
          guard let d = payload.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
          else { continue }
          if let usage = obj["usage"] as? [String: Any] {
            pt = (usage["prompt_tokens"] as? NSNumber)?.intValue ?? pt
            ct = (usage["completion_tokens"] as? NSNumber)?.intValue ?? ct
          }
          if let choices = obj["choices"] as? [[String: Any]],
            let delta = choices.first?["delta"] as? [String: Any],
            let content = delta["content"] as? String, !content.isEmpty
          {
            acc += content
            let main =
              acc.components(separatedBy: "###").first?.trimmingCharacters(
                in: .whitespacesAndNewlines) ?? acc
            if main != lastSent {
              lastSent = main
              onChunk(main)
            }
          }
        }
        if Task.isCancelled { return }
        let parts = acc.components(separatedBy: "###")
        let main = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? acc
        let notes = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        var cost = ""
        if pt > 0 || ct > 0 {
          cost = CostTracker.record(model: model, prompt: pt, completion: ct, free: isLocal)
        }
        onDone(main.isEmpty ? "（無回應）" : main, notes, cost)
      } catch {
        if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
        onDone("網路錯誤：\(error.localizedDescription)", "", "")
      }
    }
  }
}

/// 扁平按鈕：平時細框線無底色；選中(on)時填底色。
private final class FlatButton: NSButton {
  private let labelText: String
  init(_ text: String, toggle: Bool) {
    labelText = text
    super.init(frame: .zero)
    isBordered = false
    wantsLayer = true
    layer?.cornerRadius = 7
    layer?.borderWidth = 1
    if toggle { setButtonType(.pushOnPushOff) }
    translatesAutoresizingMaskIntoConstraints = false
    setContentHuggingPriority(.required, for: .horizontal)
    refresh()
  }
  required init?(coder: NSCoder) { fatalError() }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var state: NSControl.StateValue { didSet { refresh() } }
  override var intrinsicContentSize: NSSize {
    NSSize(width: labelText.count <= 1 ? 22 : 38, height: 19)
  }
  func refresh() {
    let on = state == .on
    layer?.backgroundColor =
      on ? NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor : NSColor.clear.cgColor
    layer?.borderColor = on ? NSColor.clear.cgColor : NSColor(white: 1, alpha: 0.28).cgColor
    let c: NSColor = on ? .white : NSColor(white: 1, alpha: 0.78)
    attributedTitle = NSAttributedString(
      string: labelText, attributes: [.foregroundColor: c, .font: NSFont.systemFont(ofSize: 11)])
  }
}

/// 可成為 key window 的浮窗（nonactivating 也能讓內部欄位接受輸入）。
private final class KeyablePanel: NSPanel {
  override var canBecomeKey: Bool { true }
  // 浮窗為 key 時，⌘V → 貼上剪貼簿內容並分析（⌘C 等照常給選取文字用）
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "v" {
      if let s = NSPasteboard.general.string(forType: .string),
        !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        ZhLearnHook.analyzeText(s)
      }
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}

/// 右下角縮放握把：拖曳改變視窗大小（保持左上角固定）。
private final class ResizeGrip: NSView {
  weak var win: NSWindow?
  private var startFrame = NSRect.zero
  private var startMouse = NSPoint.zero
  override var mouseDownCanMoveWindow: Bool { false }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
  override func mouseDown(with event: NSEvent) {
    startFrame = win?.frame ?? .zero
    startMouse = NSEvent.mouseLocation
  }
  override func mouseDragged(with event: NSEvent) {
    guard let w = win else { return }
    let now = NSEvent.mouseLocation
    let newW = max(w.minSize.width, startFrame.width + (now.x - startMouse.x))
    let newH = max(w.minSize.height, startFrame.height - (now.y - startMouse.y))
    var f = startFrame
    f.origin.y = startFrame.maxY - newH
    f.size = NSSize(width: newW, height: newH)
    w.setFrame(f, display: true)
  }
  override func draw(_ dirtyRect: NSRect) {
    NSColor(white: 1, alpha: 0.4).setStroke()
    let path = NSBezierPath()
    path.lineWidth = 1.2
    for off in [5.0, 9.0, 13.0] {
      path.move(to: NSPoint(x: bounds.maxX - off, y: 2))
      path.line(to: NSPoint(x: bounds.maxX - 2, y: off))
    }
    path.stroke()
  }
}

/// 朗讀整句英文。三種引擎：
/// 1) apple    — 系統內建 AVSpeechSynthesizer，離線零設定（可下載 Premium 語音更自然）。
/// 2) piper    — 內建 sherpa-onnx + Piper 神經語音：勾選即用，首次自動下載語音模型，全離線本機。
/// 3) endpoint — OpenAI 相容 TTS 端點（如本機 Kokoro-FastAPI）；連不上自動退回 apple。
@MainActor
private final class ZhLearnTTS: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
  static let shared = ZhLearnTTS()
  private let synth = AVSpeechSynthesizer()
  private var player: AVAudioPlayer?
  private var task: URLSessionDataTask?
  private var dlTask: URLSessionDownloadTask?
  private var proc: Process?
  private var downloading = false
  private var gen = 0  // 世代票：stop／新請求都會 +1，使在途的背景回呼失效（避免停止後又退回朗讀）
  /// 播放狀態變化回呼（true＝播放中，false＝停止／結束）。
  var onStateChange: ((Bool) -> Void)?
  /// 狀態文字回呼（下載進度等；空字串＝清除）。
  var onStatus: ((String) -> Void)?

  override init() {
    super.init()
    synth.delegate = self
  }

  private var busy: Bool {
    synth.isSpeaking || (player?.isPlaying ?? false) || task != nil || dlTask != nil || proc != nil
      || downloading
  }

  /// 挑選最自然的英文語音：偏好 en-US，再依音質（premium/enhanced/default）排序。
  private static let voice: AVSpeechSynthesisVoice? = {
    let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
    func score(_ v: AVSpeechSynthesisVoice) -> Int {
      (v.language == "en-US" ? 100 : 50) + v.quality.rawValue * 10
    }
    return voices.sorted { score($0) > score($1) }.first
  }()

  // 內建 Piper 引擎與語音模型路徑（純函式，可從背景執行緒安全呼叫）。
  nonisolated private static var helperPath: String {
    Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sherpa-onnx-offline-tts").path
  }
  nonisolated private static var ttsDir: String { ("~/.zhlearnime/tts" as NSString).expandingTildeInPath }
  // 依 Piper 語音 id（如 en_US-amy-medium）解析路徑；每個語音套件各自含 onnx/tokens/espeak-ng-data。
  nonisolated private static func voiceDir(_ id: String) -> String { ttsDir + "/vits-piper-\(id)" }
  nonisolated private static func onnxPath(_ id: String) -> String? {
    let dir = voiceDir(id)
    guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir),
      let onnx = items.first(where: { $0.hasSuffix(".onnx") })
    else { return nil }
    return dir + "/" + onnx
  }
  nonisolated private static func voiceReady(_ id: String) -> Bool {
    onnxPath(id) != nil && FileManager.default.fileExists(atPath: voiceDir(id) + "/tokens.txt")
  }
  nonisolated private static func voiceURL(_ id: String) -> String {
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-\(id).tar.bz2"
  }

  /// 按一下：未播放→朗讀；播放中／下載中→停止。
  func toggle(_ text: String) {
    if busy {
      stop()
      return
    }
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return }
    gen += 1
    let cfg = ZhLearnConfig.load()
    switch cfg.ttsEngine {
    case "piper": speakPiper(t, cfg: cfg)
    case "endpoint": speakEndpoint(t, cfg: cfg)
    default: speakApple(t)
    }
  }

  private func speakApple(_ t: String) {
    let speed = ZhLearnConfig.load().ttsSpeed
    let u = AVSpeechUtterance(string: t)
    u.voice = Self.voice
    // 語速：以系統預設語速為 1.0×，再乘上倍率並夾在合法範圍。
    let base = Double(AVSpeechUtteranceDefaultSpeechRate)
    u.rate = Float(
      max(Double(AVSpeechUtteranceMinimumSpeechRate),
        min(Double(AVSpeechUtteranceMaximumSpeechRate), base * speed)))
    onStateChange?(true)
    synth.speak(u)
  }

  // MARK: 內建 Piper（sherpa-onnx）

  private func speakPiper(_ t: String, cfg: ZhLearnConfig) {
    guard FileManager.default.isExecutableFile(atPath: Self.helperPath) else {
      speakApple(t)  // 引擎缺失（舊版安裝）→ 退回系統語音
      return
    }
    let id = cfg.ttsPiperVoice
    if Self.voiceReady(id) {
      runPiper(t, voiceId: id, speed: cfg.ttsSpeed)
    } else {
      downloadVoiceThenSpeak(t, voiceId: id, speed: cfg.ttsSpeed)
    }
  }

  /// 首次啟用（或換新語音）：背景下載該 Piper 語音套件，解壓後合成。
  private func downloadVoiceThenSpeak(_ t: String, voiceId: String, speed: Double) {
    if downloading { return }
    downloading = true
    onStateChange?(true)
    onStatus?("⏳ 下載語音「\(voiceId)」中…")
    try? FileManager.default.createDirectory(atPath: Self.ttsDir, withIntermediateDirectories: true)
    guard let url = URL(string: Self.voiceURL(voiceId)) else {
      downloading = false
      speakApple(t)
      return
    }
    let dir = Self.ttsDir
    let g = gen
    let dl = URLSession.shared.downloadTask(with: url) { [weak self] tmp, _, _ in
      var ok = false
      if let tmp {
        let dst = dir + "/voice.tar.bz2"
        try? FileManager.default.removeItem(atPath: dst)
        try? FileManager.default.moveItem(at: tmp, to: URL(fileURLWithPath: dst))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["xjf", dst, "-C", dir]
        do {
          try tar.run()
          tar.waitUntilExit()
          ok = tar.terminationStatus == 0
        } catch { ok = false }
        try? FileManager.default.removeItem(atPath: dst)
      }
      let done = ok && Self.voiceReady(voiceId)
      Task { @MainActor in
        guard let self, self.gen == g else { return }
        self.downloading = false
        self.dlTask = nil
        self.onStatus?("")
        if done {
          self.runPiper(t, voiceId: voiceId, speed: speed)
        } else {
          self.speakApple(t)
          self.onStatus?("語音下載失敗，暫用系統語音")
        }
      }
    }
    dlTask = dl
    dl.resume()
  }

  /// 呼叫內建 sherpa-onnx-offline-tts 合成 wav 後播放（背景執行，避免卡 UI）。
  private func runPiper(_ t: String, voiceId: String, speed: Double) {
    guard let onnx = Self.onnxPath(voiceId) else {
      speakApple(t)
      return
    }
    let dir = Self.voiceDir(voiceId)
    let out = NSTemporaryDirectory() + "zhlearn_tts.wav"
    try? FileManager.default.removeItem(atPath: out)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: Self.helperPath)
    var args = [
      "--vits-model=\(onnx)",
      "--vits-tokens=\(dir)/tokens.txt",
      "--num-threads=2",
      "--speed=\(speed)",
      "--output-filename=\(out)",
    ]
    let dataDir = dir + "/espeak-ng-data"
    if FileManager.default.fileExists(atPath: dataDir) {
      args.insert("--vits-data-dir=\(dataDir)", at: 2)
    }
    args.append(t)
    p.arguments = args
    p.standardOutput = nil
    p.standardError = nil
    proc = p
    onStateChange?(true)
    let g = gen
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      var ok = false
      do {
        try p.run()
        p.waitUntilExit()
        ok = p.terminationStatus == 0
      } catch { ok = false }
      Task { @MainActor in
        guard let self, self.gen == g else { return }
        self.proc = nil
        guard ok, let pl = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: out)) else {
          self.speakApple(t)
          return
        }
        pl.delegate = self
        self.player = pl
        pl.play()
      }
    }
  }

  /// 走 OpenAI 相容 /v1/audio/speech：POST {model,input,voice,response_format:wav} → 播放 wav。
  private func speakEndpoint(_ t: String, cfg: ZhLearnConfig) {
    guard let url = URL(string: cfg.ttsURL) else {
      speakApple(t)
      return
    }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = 30
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !cfg.ttsApiKey.isEmpty {
      req.setValue("Bearer \(cfg.ttsApiKey)", forHTTPHeaderField: "Authorization")
    }
    let body: [String: Any] = [
      "model": "kokoro", "input": t, "voice": cfg.ttsVoice, "response_format": "wav",
      "speed": cfg.ttsSpeed,
    ]
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    onStateChange?(true)
    let g = gen
    let dataTask = URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
      // 只捕捉 Sendable 值（status/data/t）再跳回 MainActor 觸碰 self。
      let status = (resp as? HTTPURLResponse)?.statusCode
      Task { @MainActor in
        guard let self, self.gen == g else { return }
        self.task = nil
        guard status == 200, let data, let p = try? AVAudioPlayer(data: data) else {
          // 端點連不上／回應異常：自動退回系統語音，確保按下去一定有聲音。
          self.speakApple(t)
          return
        }
        p.delegate = self
        self.player = p
        p.play()
      }
    }
    self.task = dataTask
    dataTask.resume()
  }

  func stop() {
    gen += 1  // 讓所有在途回呼失效
    task?.cancel()
    task = nil
    dlTask?.cancel()
    dlTask = nil
    downloading = false
    proc?.terminate()
    proc = nil
    if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    if let p = player, p.isPlaying { p.stop() }
    player = nil
    onStatus?("")
    onStateChange?(false)
  }

  // 系統在主執行緒回呼這些 delegate；標 nonisolated 以滿足協定，內部跳回 MainActor。
  nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
    Task { @MainActor in self.onStateChange?(false) }
  }
  nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance) {
    Task { @MainActor in self.onStateChange?(false) }
  }
  nonisolated func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
    Task { @MainActor in
      self.player = nil
      self.onStateChange?(false)
    }
  }
}

private final class ZhLearnPanel: NSObject {
  static let shared = ZhLearnPanel()
  private var panel: NSPanel?
  private var transLabel: NSTextField?
  private var notesLabel: NSTextField?
  private var costLabel: NSTextField?
  private var dividerView: NSBox?
  private var speakerBtn: FlatButton?
  private var currentEnglish = ""
  private var styleButtons: [FlatButton] = []
  private var positioned = false
  private let styles = [("business", "商業"), ("scientific", "科學"), ("casual", "輕鬆")]

  private func makeLabel(_ size: CGFloat, _ color: NSColor) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: "")
    l.font = NSFont.systemFont(ofSize: size)
    l.textColor = color
    l.alignment = .left
    l.backgroundColor = .clear
    l.isBezeled = false
    l.isEditable = false
    l.isSelectable = false
    l.translatesAutoresizingMaskIntoConstraints = false
    return l
  }

  private func ensure() {
    if panel != nil { return }
    let rect = NSRect(x: 0, y: 0, width: 360, height: 170)
    let p = KeyablePanel(
      contentRect: rect, styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered, defer: false)
    p.level = .floating
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = true
    p.hidesOnDeactivate = false
    p.isMovableByWindowBackground = true  // 拖背景移動
    p.minSize = NSSize(width: 260, height: 100)
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

    let vev = NSVisualEffectView(frame: rect)
    vev.material = .hudWindow
    vev.blendingMode = .behindWindow
    vev.state = .active
    vev.wantsLayer = true
    vev.layer?.cornerRadius = 14
    vev.layer?.masksToBounds = true
    p.contentView = vev

    // 主譯文（粗、白、較大；可選取複製）
    let trans = makeLabel(16, .white)
    trans.font = NSFont.systemFont(ofSize: 16, weight: .medium)
    trans.isSelectable = true
    // 朗讀喇叭：併入底部控制列（見下方 btnStack），不另佔一行。
    let speaker = FlatButton("🔊", toggle: false)
    speaker.target = self
    speaker.action = #selector(speakerTapped)
    // 分隔線
    let divider = NSBox()
    divider.boxType = .separator
    divider.translatesAutoresizingMaskIntoConstraints = false
    // 說明 / 建議（次級、行距較鬆）
    let notes = makeLabel(12, NSColor(white: 1, alpha: 0.66))
    let textStack = NSStackView(views: [trans, divider, notes])
    textStack.orientation = .vertical
    textStack.alignment = .leading
    textStack.spacing = 7
    textStack.translatesAutoresizingMaskIntoConstraints = false

    let cost = makeLabel(9.5, NSColor(white: 1, alpha: 0.4))
    cost.maximumNumberOfLines = 1

    let closeBtn = FlatButton("✕", toggle: false)
    closeBtn.target = self
    closeBtn.action = #selector(closeTapped)

    let btnStack = NSStackView()
    btnStack.orientation = .horizontal
    btnStack.spacing = 5
    btnStack.translatesAutoresizingMaskIntoConstraints = false
    btnStack.addArrangedSubview(speaker)  // 🔊 放控制列最左
    for (i, (_, name)) in styles.enumerated() {
      let b = FlatButton(name, toggle: true)
      b.target = self
      b.action = #selector(styleTapped(_:))
      b.tag = i
      btnStack.addArrangedSubview(b)
      styleButtons.append(b)
    }
    let gearBtn = FlatButton("⚙", toggle: false)
    gearBtn.target = self
    gearBtn.action = #selector(settingsTapped)
    btnStack.addArrangedSubview(gearBtn)

    // 右下角縮放握把（拖它改視窗大小）
    let grip = ResizeGrip()
    grip.win = p
    grip.translatesAutoresizingMaskIntoConstraints = false

    vev.addSubview(textStack)
    vev.addSubview(btnStack)
    vev.addSubview(closeBtn)
    vev.addSubview(cost)
    vev.addSubview(grip)

    let region = NSLayoutGuide()
    vev.addLayoutGuide(region)

    NSLayoutConstraint.activate([
      closeBtn.trailingAnchor.constraint(equalTo: vev.trailingAnchor, constant: -8),
      closeBtn.topAnchor.constraint(equalTo: vev.topAnchor, constant: 8),

      grip.trailingAnchor.constraint(equalTo: vev.trailingAnchor, constant: -3),
      grip.bottomAnchor.constraint(equalTo: vev.bottomAnchor, constant: -3),
      grip.widthAnchor.constraint(equalToConstant: 15),
      grip.heightAnchor.constraint(equalToConstant: 15),

      btnStack.trailingAnchor.constraint(equalTo: grip.leadingAnchor, constant: -6),
      btnStack.bottomAnchor.constraint(equalTo: vev.bottomAnchor, constant: -10),

      cost.leadingAnchor.constraint(equalTo: vev.leadingAnchor, constant: 14),
      cost.centerYAnchor.constraint(equalTo: btnStack.centerYAnchor),
      cost.trailingAnchor.constraint(lessThanOrEqualTo: btnStack.leadingAnchor, constant: -6),

      region.topAnchor.constraint(equalTo: vev.topAnchor, constant: 14),
      region.bottomAnchor.constraint(equalTo: btnStack.topAnchor, constant: -10),

      textStack.leadingAnchor.constraint(equalTo: vev.leadingAnchor, constant: 16),
      textStack.trailingAnchor.constraint(equalTo: vev.trailingAnchor, constant: -16),
      textStack.centerYAnchor.constraint(equalTo: region.centerYAnchor),
      textStack.topAnchor.constraint(greaterThanOrEqualTo: region.topAnchor, constant: 2),

      divider.widthAnchor.constraint(equalTo: textStack.widthAnchor),
    ])

    self.panel = p
    self.transLabel = trans
    self.notesLabel = notes
    self.costLabel = cost
    self.dividerView = divider
    self.speakerBtn = speaker
    // 播放狀態驅動喇叭高亮（播放中＝accent 高亮，結束自動還原）。
    ZhLearnTTS.shared.onStateChange = { [weak self] playing in
      DispatchQueue.main.async { self?.speakerBtn?.state = playing ? .on : .off }
    }
    // 下載/狀態文字暫顯在左下成本列，清空時還原成本摘要。
    ZhLearnTTS.shared.onStatus = { [weak self] msg in
      DispatchQueue.main.async {
        self?.costLabel?.stringValue = msg.isEmpty ? CostTracker.summary() : msg
      }
    }
    refreshButtons()
  }

  @objc private func styleTapped(_ sender: NSButton) {
    ZhLearnConfig.setStyleQuick(styles[sender.tag].0)
    refreshButtons()
    ZhLearnHook.retranslateLast()
  }
  @objc private func closeTapped() {
    ZhLearnHook.userClosed = true
    ZhLearnTTS.shared.stop()
    panel?.orderOut(nil)
  }

  /// 按喇叭：朗讀整句英文；播放中再按一次即停止。非英文（如「翻譯中…」）忽略。
  @objc private func speakerTapped() {
    guard currentEnglish.contains(where: { $0.isLetter && $0.isASCII }) else { return }
    ZhLearnTTS.shared.toggle(currentEnglish)
  }

  func hide() {
    ZhLearnTTS.shared.stop()
    panel?.orderOut(nil)
  }

  /// 串流中的輕量更新：只換主譯文文字（不重定位、不重讀設定，避免卡頓）。
  func streamUpdate(_ text: String) {
    ensure()
    currentEnglish = text
    transLabel?.stringValue = text
    notesLabel?.isHidden = true
    dividerView?.isHidden = true
    panel?.orderFrontRegardless()
  }

  func refreshCost() {
    if panel != nil { costLabel?.stringValue = CostTracker.summary() }
  }
  @objc private func settingsTapped() {
    ZhLearnSettings.shared.open()
  }

  /// 設定滑桿即時預覽透明度。
  func setOpacity(_ v: Double) {
    ensure()
    panel?.alphaValue = CGFloat(v)
    panel?.orderFrontRegardless()
  }

  private func refreshButtons() {
    let cur = ZhLearnConfig.load().style
    for (i, b) in styleButtons.enumerated() {
      b.state = (styles[i].0 == cur) ? .on : .off
    }
  }

  func show(_ text: String, notes: String, cost: String, at caret: NSPoint) {
    ensure()
    ZhLearnTTS.shared.stop()  // 新內容到達：停掉上一句的朗讀
    currentEnglish = text
    transLabel?.stringValue = text
    let hasNotes = !notes.isEmpty
    notesLabel?.isHidden = !hasNotes
    dividerView?.isHidden = !hasNotes
    if hasNotes {
      let full = NSMutableAttributedString()
      let lines = notes.components(separatedBy: "\n")
      for (i, line) in lines.enumerated() {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        para.paragraphSpacing = 3
        if line.hasPrefix("・") {
          para.headIndent = 15  // 懸掛縮排：換行對齊「・」後文字
          para.firstLineHeadIndent = 0
        }
        let s = line + (i < lines.count - 1 ? "\n" : "")
        full.append(
          NSAttributedString(
            string: s,
            attributes: [
              .font: NSFont.systemFont(ofSize: 12),
              .foregroundColor: NSColor(white: 1, alpha: 0.66),
              .paragraphStyle: para,
            ]))
      }
      notesLabel?.attributedStringValue = full
    }
    if !cost.isEmpty { costLabel?.stringValue = cost }
    refreshButtons()
    guard let p = panel else { return }
    p.alphaValue = CGFloat(ZhLearnConfig.load().opacity)
    if !positioned {
      let w = p.frame.width
      if caret.x <= 1, caret.y <= 1 {
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        p.setFrameOrigin(NSPoint(x: screen.midX - w / 2, y: screen.minY + 140))
      } else {
        p.setFrameOrigin(NSPoint(x: caret.x, y: caret.y - p.frame.height - 6))
      }
      positioned = true
    }
    p.orderFrontRegardless()
  }
}

/// 原生設定視窗：API Key、模型、服務商、Base URL、重置秒數。
private final class ZhLearnSettings: NSObject {
  static let shared = ZhLearnSettings()
  private var window: NSWindow?
  private let apiKeyField = NSTextField()
  private let modelField = NSTextField()
  private let baseURLField = NSTextField()
  private let resetField = NSTextField()
  private let providerPopup = NSPopUpButton()
  private let liveCheck = NSButton(
    checkboxWithTitle: "啟用即時翻譯（打字自動翻譯）", target: nil, action: nil)
  private let englishAssistCheck = NSButton(
    checkboxWithTitle: "英文輸入時提供寫作助理（改寫＋建議）", target: nil, action: nil)
  private let preciseCheck = NSButton(
    checkboxWithTitle: "精準翻譯（理解整句＋前文，較吃 token）", target: nil, action: nil)
  private let domainField = NSTextField()
  private let ttsEnginePopup = NSPopUpButton()
  // 顯示名稱 ↔ 設定值
  private let ttsEngineItems: [(String, String)] = [
    ("系統語音（離線、零設定）", "apple"),
    ("高品質本機（Piper，首次自動下載 ~64MB）", "piper"),
    ("自訂 OpenAI 相容端點（如 Kokoro）", "endpoint"),
  ]
  private let ttsEndpointField = NSTextField()
  private let ttsVoiceField = NSTextField()
  private let ttsPiperVoicePopup = NSPopUpButton()
  // 內建 Piper 可選語音（顯示名 ↔ sherpa 套件 id）
  private let ttsPiperVoiceItems: [(String, String)] = [
    ("Amy — 美式女聲（預設）", "en_US-amy-medium"),
    ("HFC 女聲 — 美式、清晰", "en_US-hfc_female-medium"),
    ("HFC 男聲 — 美式", "en_US-hfc_male-medium"),
    ("Ryan — 美式男聲、高品質", "en_US-ryan-high"),
    ("LibriTTS — 美式、自然", "en_US-libritts_r-medium"),
    ("Lessac — 美式女聲、清楚", "en_US-lessac-medium"),
    ("Alba — 英式女聲", "en_GB-alba-medium"),
    ("Cori — 英式女聲、高品質", "en_GB-cori-high"),
  ]
  private let ttsSpeedSlider = NSSlider(
    value: 1.0, minValue: 0.5, maxValue: 2.0, target: nil, action: nil)
  private let opacitySlider = NSSlider(
    value: 0.96, minValue: 0.3, maxValue: 1.0, target: nil, action: nil)
  private let shortcutRecorder = ShortcutRecorder()
  private var profiles: [String: [String: String]] = [:]  // 各服務商各自的 apiKey/model/baseUrl
  private var activeProvider = "openai"

  private func defaultModel(_ p: String) -> String {
    switch p {
    case "ollama": return "qwen2.5"
    case "lmstudio": return ""
    case "openrouter": return "openai/gpt-4o-mini"
    default: return "gpt-4o-mini"
    }
  }
  private func loadProviderFields(_ p: String) {
    let prof = profiles[p] ?? [:]
    apiKeyField.stringValue = prof["apiKey"] ?? ""
    modelField.stringValue = prof["model"] ?? defaultModel(p)
    baseURLField.stringValue = prof["baseUrl"] ?? ""
  }
  private func stashCurrentProvider() {
    profiles[activeProvider] = [
      "apiKey": apiKeyField.stringValue.trimmingCharacters(in: .whitespaces),
      "model": modelField.stringValue.trimmingCharacters(in: .whitespaces),
      "baseUrl": baseURLField.stringValue.trimmingCharacters(in: .whitespaces),
    ]
  }
  @objc private func providerChanged() {
    stashCurrentProvider()  // 先存舊服務商
    activeProvider = providerPopup.titleOfSelectedItem ?? "openai"
    loadProviderFields(activeProvider)  // 載入新服務商
  }

  func open() {
    if window == nil { build() }
    let c = ZhLearnConfig.load()
    profiles = ZhLearnConfig.rawProfiles()
    activeProvider = c.provider
    // 首次無 profile：用目前解析出的設定當作此服務商的 profile（沿用舊設定）
    if profiles[activeProvider] == nil {
      profiles[activeProvider] = ["apiKey": c.apiKey, "model": c.model, "baseUrl": c.baseURL]
    }
    providerPopup.selectItem(withTitle: activeProvider)
    loadProviderFields(activeProvider)
    resetField.stringValue = String(format: "%g", c.resetSec)
    englishAssistCheck.state = c.englishAssist ? .on : .off
    liveCheck.state = c.liveEnabled ? .on : .off
    preciseCheck.state = c.preciseMode ? .on : .off
    domainField.stringValue = c.domain
    if let idx = ttsEngineItems.firstIndex(where: { $0.1 == c.ttsEngine }) {
      ttsEnginePopup.selectItem(at: idx)
    }
    if let idx = ttsPiperVoiceItems.firstIndex(where: { $0.1 == c.ttsPiperVoice }) {
      ttsPiperVoicePopup.selectItem(at: idx)
    }
    ttsSpeedSlider.doubleValue = c.ttsSpeed
    ttsEndpointField.stringValue = c.ttsEndpoint
    ttsVoiceField.stringValue = c.ttsVoice
    opacitySlider.doubleValue = c.opacity
    shortcutRecorder.set(keyCode: c.hotkeyKeyCode, mods: c.hotkeyMods, label: c.hotkeyLabel)
    NSApp.activate(ignoringOtherApps: true)
    window?.center()
    window?.makeKeyAndOrderFront(nil)
  }

  private func labeled(_ title: String, _ field: NSView) -> NSStackView {
    let l = NSTextField(labelWithString: title)
    l.font = NSFont.systemFont(ofSize: 11)
    l.textColor = .secondaryLabelColor
    let s = NSStackView(views: [l, field])
    s.orientation = .vertical
    s.alignment = .leading
    s.spacing = 3
    return s
  }

  private func build() {
    providerPopup.addItems(withTitles: ["openai", "openrouter", "ollama", "lmstudio"])
    providerPopup.translatesAutoresizingMaskIntoConstraints = false
    providerPopup.target = self
    providerPopup.action = #selector(providerChanged)
    for f in [apiKeyField, modelField, baseURLField, resetField, domainField, ttsEndpointField, ttsVoiceField] {
      f.translatesAutoresizingMaskIntoConstraints = false
      f.widthAnchor.constraint(equalToConstant: 470).isActive = true
    }
    ttsEnginePopup.addItems(withTitles: ttsEngineItems.map { $0.0 })
    ttsEnginePopup.translatesAutoresizingMaskIntoConstraints = false
    ttsPiperVoicePopup.addItems(withTitles: ttsPiperVoiceItems.map { $0.0 })
    ttsPiperVoicePopup.translatesAutoresizingMaskIntoConstraints = false
    ttsSpeedSlider.translatesAutoresizingMaskIntoConstraints = false
    ttsSpeedSlider.numberOfTickMarks = 7
    ttsSpeedSlider.allowsTickMarkValuesOnly = false
    ttsSpeedSlider.widthAnchor.constraint(equalToConstant: 470).isActive = true
    preciseCheck.translatesAutoresizingMaskIntoConstraints = false
    englishAssistCheck.translatesAutoresizingMaskIntoConstraints = false
    liveCheck.translatesAutoresizingMaskIntoConstraints = false
    opacitySlider.translatesAutoresizingMaskIntoConstraints = false
    opacitySlider.isContinuous = true
    opacitySlider.target = self
    opacitySlider.action = #selector(opacityChanged)
    opacitySlider.widthAnchor.constraint(equalToConstant: 470).isActive = true
    // 分頁，避免設定一路往下拉太長。
    let tabs = NSTabView()
    tabs.translatesAutoresizingMaskIntoConstraints = false
    tabs.addTabViewItem(
      tabItem("翻譯", [
        labeled("API Key", apiKeyField),
        labeled("模型 Model", modelField),
        labeled("服務商 Provider", providerPopup),
        labeled("自訂 Base URL（選填，留空用預設）", baseURLField),
        labeled("用字領域 Domain（如 醫學/法律/軟體；選填）", domainField),
        liveCheck,
        englishAssistCheck,
        preciseCheck,
      ]))
    tabs.addTabViewItem(
      tabItem("朗讀 TTS", [
        labeled("🔊 朗讀引擎 TTS", ttsEnginePopup),
        labeled("朗讀語速 Speed（0.5–2.0×，預設 1）", ttsSpeedSlider),
        labeled("高品質語音 Piper（選擇後首次自動下載）", ttsPiperVoicePopup),
        labeled("自訂端點 Endpoint（僅「自訂端點」模式用）", ttsEndpointField),
        labeled("端點語音 Voice（端點用，如 af_heart）", ttsVoiceField),
      ]))
    tabs.addTabViewItem(
      tabItem("外觀 & 熱鍵", [
        labeled("透明度 Opacity（拖曳即時預覽）", opacitySlider),
        labeled("重置秒數 Reset（秒，預設 2）", resetField),
        labeled("反白翻譯熱鍵（需輔助使用權限；Office 讀不到）", shortcutRecorder),
      ]))

    let save = NSButton(title: "儲存", target: self, action: #selector(saveTapped))
    save.bezelStyle = .rounded
    save.keyEquivalent = "\r"
    save.translatesAutoresizingMaskIntoConstraints = false

    let resetCostBtn = NSButton(
      title: "重置 token 計數", target: self, action: #selector(resetCostTapped))
    resetCostBtn.bezelStyle = .rounded
    resetCostBtn.translatesAutoresizingMaskIntoConstraints = false

    let w = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 540, height: 470),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    w.title = "打即通 — 設定"
    w.isReleasedWhenClosed = false
    let cv = w.contentView!
    cv.addSubview(tabs)
    cv.addSubview(save)
    cv.addSubview(resetCostBtn)
    NSLayoutConstraint.activate([
      tabs.topAnchor.constraint(equalTo: cv.topAnchor, constant: 12),
      tabs.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
      tabs.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
      tabs.bottomAnchor.constraint(equalTo: save.topAnchor, constant: -12),
      save.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
      save.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -16),
      resetCostBtn.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
      resetCostBtn.centerYAnchor.constraint(equalTo: save.centerYAnchor),
    ])
    window = w
  }

  /// 把一組設定列包成一個分頁（內容靠上、靠左）。
  private func tabItem(_ title: String, _ rows: [NSView]) -> NSTabViewItem {
    let form = NSStackView(views: rows)
    form.orientation = .vertical
    form.alignment = .leading
    form.spacing = 12
    form.translatesAutoresizingMaskIntoConstraints = false
    let container = NSView()
    container.addSubview(form)
    NSLayoutConstraint.activate([
      form.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
      form.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
      form.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
    ])
    let item = NSTabViewItem()
    item.label = title
    item.view = container
    return item
  }

  @objc private func resetCostTapped() { ZhLearnHook.resetCost() }

  @objc private func opacityChanged() {
    ZhLearnPanel.shared.setOpacity(opacitySlider.doubleValue)
  }

  @objc private func saveTapped() {
    let reset = Double(resetField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 2
    stashCurrentProvider()  // 把目前欄位存進此服務商 profile
    ZhLearnConfig.write([
      "provider": activeProvider,
      "profiles": profiles,  // 各服務商各自的 apiKey/model/baseUrl
      "resetSec": reset,
      "englishAssist": englishAssistCheck.state == .on,
      "liveEnabled": liveCheck.state == .on,
      "preciseMode": preciseCheck.state == .on,
      "domain": domainField.stringValue.trimmingCharacters(in: .whitespaces),
      "ttsEngine": ttsEngineItems[max(0, ttsEnginePopup.indexOfSelectedItem)].1,
      "ttsPiperVoice": ttsPiperVoiceItems[max(0, ttsPiperVoicePopup.indexOfSelectedItem)].1,
      "ttsSpeed": (ttsSpeedSlider.doubleValue * 100).rounded() / 100,
      "ttsEndpoint": ttsEndpointField.stringValue.trimmingCharacters(in: .whitespaces),
      "ttsVoice": ttsVoiceField.stringValue.trimmingCharacters(in: .whitespaces),
      "opacity": opacitySlider.doubleValue,
      "hotkeyKeyCode": shortcutRecorder.keyCode,
      "hotkeyMods": shortcutRecorder.carbonModifiers,
      "hotkeyLabel": shortcutRecorder.label,
    ])
    ZhLearnHook.reRegisterHotkey()
    ZhLearnHook.hidePanelIfLiveOff()
    window?.close()
  }
}

/// 全域熱鍵（Carbon RegisterEventHotKey）。
private final class HotkeyManager {
  static let shared = HotkeyManager()
  private var ref: EventHotKeyRef?
  private var installed = false

  func register(keyCode: Int, mods: Int) {
    if !installed {
      installed = true
      var spec = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
      InstallEventHandler(
        GetEventDispatcherTarget(),
        { _, _, _ -> OSStatus in
          DispatchQueue.main.async { ZhLearnHook.hotkeyFired() }
          return noErr
        }, 1, &spec, nil, nil)
    }
    if let r = ref {
      UnregisterEventHotKey(r)
      ref = nil
    }
    let hkID = EventHotKeyID(signature: OSType(0x5A48_4B31), id: 1)
    RegisterEventHotKey(UInt32(keyCode), UInt32(mods), hkID, GetEventDispatcherTarget(), 0, &ref)
  }
}

private enum ZhKeys {
  static func carbonMods(from flags: NSEvent.ModifierFlags) -> Int {
    var m = 0
    if flags.contains(.command) { m |= cmdKey }
    if flags.contains(.option) { m |= optionKey }
    if flags.contains(.control) { m |= controlKey }
    if flags.contains(.shift) { m |= shiftKey }
    return m
  }
  static func symbols(_ mods: Int) -> String {
    var s = ""
    if mods & controlKey != 0 { s += "⌃" }
    if mods & optionKey != 0 { s += "⌥" }
    if mods & shiftKey != 0 { s += "⇧" }
    if mods & cmdKey != 0 { s += "⌘" }
    return s
  }
}

/// 點一下開始錄製，按下任意「修飾鍵＋鍵」即設為熱鍵。
private final class ShortcutRecorder: NSButton {
  var keyCode = 17
  var carbonModifiers = cmdKey | optionKey
  var label = "⌥⌘T"
  private var monitor: Any?

  init() {
    super.init(frame: .zero)
    bezelStyle = .rounded
    target = self
    action = #selector(startRecording)
    translatesAutoresizingMaskIntoConstraints = false
    refresh()
  }
  required init?(coder: NSCoder) { fatalError() }

  func set(keyCode: Int, mods: Int, label: String) {
    self.keyCode = keyCode
    self.carbonModifiers = mods
    self.label = label
    refresh()
  }
  private func refresh() { title = "熱鍵：\(label)（點此重設）" }

  @objc private func startRecording() {
    title = "請按下要用的組合鍵…"
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
      guard let self = self else { return ev }
      let mods = ZhKeys.carbonMods(from: ev.modifierFlags)
      if mods == 0 { return ev }  // 需至少一個修飾鍵
      self.keyCode = Int(ev.keyCode)
      self.carbonModifiers = mods
      self.label = ZhKeys.symbols(mods) + (ev.charactersIgnoringModifiers ?? "").uppercased()
      self.refresh()
      if let m = self.monitor { NSEvent.removeMonitor(m); self.monitor = nil }
      return nil
    }
  }
}

/// vChewing 輸入法選單附加項：即時翻譯開關 + 翻譯風格切換。
/// action 必須掛在 SessionCtl（IMK 選單走 responder chain 到輸入控制器，自訂 target 不會被呼叫）。
enum ZhLearnMenu {
  private static let styles = [("business", "商業"), ("scientific", "科學嚴謹"), ("casual", "輕鬆")]
  static func append(to menu: NSMenu, ctl: SessionCtl) {
    menu.addItem(.separator())
    let live = NSMenuItem(
      title: "啟用即時翻譯", action: #selector(SessionCtl.zhToggleLive(_:)), keyEquivalent: "")
    live.target = ctl
    live.state = ZhLearnHook.liveEnabledNow() ? .on : .off
    menu.addItem(live)
    let header = NSMenuItem(title: "中文學英文 — 翻譯風格", action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    let cur = ZhLearnHook.currentStyle()
    for (key, name) in styles {
      let it = NSMenuItem(
        title: "  \(name)", action: #selector(SessionCtl.zhPickStyle(_:)), keyEquivalent: "")
      it.target = ctl
      it.representedObject = key
      it.state = (key == cur) ? .on : .off
      menu.addItem(it)
    }
  }
}

extension SessionCtl {
  @objc public func zhToggleLive(_ sender: NSMenuItem) {
    ZhLearnHook.menuToggleLive()
    sender.state = ZhLearnHook.liveEnabledNow() ? .on : .off
  }
  @objc public func zhPickStyle(_ sender: NSMenuItem) {
    guard let key = sender.representedObject as? String else { return }
    ZhLearnHook.menuSetStyle(key)
  }
}
