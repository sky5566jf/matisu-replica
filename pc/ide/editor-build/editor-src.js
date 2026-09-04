// MatisuAuto IDE 编辑器：CodeMirror 6 + 极简 LSP 客户端（WebSocket 桥到 lua-language-server）
import { EditorState } from '@codemirror/state';
import { EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter, drawSelection } from '@codemirror/view';
import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands';
import { StreamLanguage, syntaxHighlighting, defaultHighlightStyle, HighlightStyle, indentOnInput, bracketMatching, foldGutter, foldAll, unfoldAll, foldCode, unfoldCode, foldService, toggleFold as cmToggleFold, codeFolding, foldable, foldEffect, unfoldEffect, foldState } from '@codemirror/language';
import { indentationMarkers } from '@replit/codemirror-indentation-markers';
import { autocompletion, closeBrackets, closeBracketsKeymap, completionKeymap } from '@codemirror/autocomplete';
import { linter, lintGutter, setDiagnostics } from '@codemirror/lint';
import { hoverTooltip } from '@codemirror/view';
import { lua } from '@codemirror/legacy-modes/mode/lua';
import { tags as t } from '@lezer/highlight';

// ---------------- 极简 LSP 客户端（JSON-RPC over WebSocket） ----------------
class LspClient {
  constructor(url) {
    this.url = url;
    this.seq = 0;
    this.pending = new Map();   // id -> {resolve, reject}
    this.handlers = new Map();  // method -> cb
    this.ready = false;
    this.rootUri = null;
  }
  connect(rootUri) {
    this.rootUri = rootUri;
    return new Promise((resolve, reject) => {
      let settled = false;
      const ws = new WebSocket(this.url);
      this.ws = ws;
      ws.onmessage = (ev) => this._onMsg(ev.data);
      ws.onclose = () => { this.ready = false; this._flushErr(new Error('LSP 连接断开')); };
      ws.onerror = () => { if (!settled) { settled = true; reject(new Error('LSP WebSocket 连接失败')); } };
      ws.onopen = () => {
        // 注意：不传 initializationOptions——客户端 settings 会覆盖服务端 scripts/.luarc.json
        // （其中 workspace.library 指向 meta 注解；客户端传值反而使其失效），配置一律走 .luarc.json
        this.request('initialize', {
          processId: null,
          rootUri,
          capabilities: {
            textDocument: {
              synchronization: { didSave: false, dynamicRegistration: false },
              completion: { completionItem: { snippetSupport: false, documentationFormat: ['plaintext', 'markdown'] } },
              hover: { contentFormat: ['plaintext', 'markdown'] },
              publishDiagnostics: {},
            },
            workspace: { configuration: false },
          },
          clientInfo: { name: 'MatisuAuto-IDE' },
        }).then((r) => {
          this.notify('initialized', {});
          this.ready = true;
          settled = true;
          resolve(r);
        }).catch((e) => { settled = true; reject(e); });
      };
    });
  }
  _flushErr(e) { for (const p of this.pending.values()) p.reject(e); this.pending.clear(); }
  _onMsg(data) {
    let msg;
    try { msg = JSON.parse(data); } catch (_) { return; }
    if (msg.id !== undefined && (msg.result !== undefined || msg.error !== undefined)) {
      const p = this.pending.get(msg.id);
      if (p) { this.pending.delete(msg.id); msg.error ? p.reject(new Error(msg.error.message || 'LSP error')) : p.resolve(msg.result); }
      return;
    }
    if (msg.id !== undefined && msg.method) {
      // 服务器请求（如 workspace/configuration）——统一空响应
      this._send({ jsonrpc: '2.0', id: msg.id, result: msg.method === 'workspace/configuration' ? (msg.params.items || []).map(() => null) : null });
      return;
    }
    const cb = this.handlers.get(msg.method);
    if (cb) cb(msg.params);
  }
  _send(obj) { if (this.ws && this.ws.readyState === 1) this.ws.send(JSON.stringify(obj)); }
  request(method, params) {
    const id = ++this.seq;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this._send({ jsonrpc: '2.0', id, method, params });
      setTimeout(() => { if (this.pending.has(id)) { this.pending.delete(id); reject(new Error('LSP 超时: ' + method)); } }, 15000);
    });
  }
  notify(method, params) { this._send({ jsonrpc: '2.0', method, params }); }
  on(method, cb) { this.handlers.set(method, cb); }
}

// ---------------- 主题 ----------------
const darkHl = HighlightStyle.define([
  { tag: t.keyword, color: '#c792ea' },
  { tag: [t.string, t.special(t.string)], color: '#c3e88d' },
  { tag: [t.number, t.bool, t.null], color: '#f78c6c' },
  { tag: t.comment, color: '#546e7a', fontStyle: 'italic' },
  { tag: t.function(t.variableName), color: '#82aaff' },
  { tag: t.standard(t.variableName), color: '#89ddff' },
  { tag: t.operator, color: '#89ddff' },
]);

const darkTheme = EditorView.theme({
  '&': { backgroundColor: '#14161a', color: '#d6dbe2', height: '100%', fontSize: '13px' },
  '.cm-content': { fontFamily: "'Cascadia Code', Consolas, 'Courier New', monospace", caretColor: '#7aa2f7', padding: '6px 0' },
  '.cm-gutters': { backgroundColor: '#101216', color: '#4b5263', border: 'none', borderRight: '1px solid #23262d' },
  '.cm-activeLine': { backgroundColor: '#1b1e25' },
  '.cm-activeLineGutter': { backgroundColor: '#1b1e25', color: '#8b93a5' },
  '&.cm-focused .cm-selectionBackground, .cm-selectionBackground': { backgroundColor: '#26456b' },
  '.cm-cursor': { borderLeftColor: '#7aa2f7' },
  '.cm-tooltip': { backgroundColor: '#1c1f26', border: '1px solid #333a45', color: '#d6dbe2' },
  '.cm-tooltip-autocomplete ul li[aria-selected]': { backgroundColor: '#26456b', color: '#fff' },
  '.cm-panels': { backgroundColor: '#1c1f26', color: '#d6dbe2' },
  '.cm-lintRange-error': { textDecoration: 'underline wavy #f44747 1px' },
  '.cm-lintRange-warning': { textDecoration: 'underline wavy #cca700 1px' },
  // 折叠标记：对齐原版 ⊞/⊟ 红色方块
  '.cm-foldGutter .cm-gutterElement': { color: '#e05c66', cursor: 'pointer', fontSize: '12px', lineHeight: '18px', padding: '0 4px' },
  '.cm-foldGutter .cm-gutterElement:hover': { color: '#ff7b84' },
}, { dark: true });

// 折叠标记 DOM：⊟=可展开（已折叠块） / ⊞=可折叠 —— 与原版一致的方块图形
function foldMarkerDOM(open) {
  const el = document.createElement('span');
  el.textContent = open ? '⊟' : '⊞';
  el.title = open ? '展开' : '折叠';
  return el;
}

// ---------------- LSP <-> CM6 桥 ----------------
function posToOffset(doc, pos) {
  const line = doc.line(Math.min(pos.line + 1, doc.lines));
  return Math.min(line.from + pos.character, line.to);
}
function offsetToPos(doc, off) {
  const line = doc.lineAt(off);
  return { line: line.number - 1, character: off - line.from };
}

function lspCompletionSource(lsp, getUri) {
  return async (ctx) => {
    if (!lsp || !lsp.ready) return null;
    const pos = offsetToPos(ctx.state.doc, ctx.pos);
    try {
      const r = await lsp.request('textDocument/completion', {
        textDocument: { uri: getUri() }, position: pos,
        context: { triggerKind: ctx.explicit ? 1 : 2 },
      });
      if (!r) return null;
      const items = Array.isArray(r) ? r : (r.items || []);
      const word = ctx.matchBefore(/[\w.]*/);
      const from = word ? word.from : ctx.pos;
      return {
        from,
        options: items.slice(0, 200).map((it) => ({
          label: it.label,
          type: ({ 3: 'function', 6: 'variable', 5: 'property', 10: 'property', 7: 'class', 9: 'namespace', 14: 'keyword', 1: 'text', 21: 'constant' })[it.kind] || 'text',
          detail: it.detail ? String(it.detail).slice(0, 80) : undefined,
          info: it.documentation ? (typeof it.documentation === 'string' ? it.documentation : (it.documentation.value || '')) : undefined,
          apply: it.insertText || it.label,
        })),
        validFor: /^[\w.]*$/,
      };
    } catch (_) { return null; }
  };
}

function lspHover(getLsp, getUri) {
  return hoverTooltip(async (view, pos) => {
    const lsp = getLsp();
    if (!lsp || !lsp.ready) return null;
    const p = offsetToPos(view.state.doc, pos);
    try {
      const r = await lsp.request('textDocument/hover', { textDocument: { uri: getUri() }, position: p });
      if (!r || !r.contents) return null;
      const c = r.contents;
      let text = '';
      if (typeof c === 'string') text = c;
      else if (Array.isArray(c)) text = c.map((x) => (typeof x === 'string' ? x : x.value || '')).join('\n');
      else text = c.value || '';
      if (!text.trim()) return null;
      return {
        pos, end: pos,
        above: true,
        create() {
          const dom = document.createElement('div');
          dom.style.cssText = 'max-width:520px;padding:6px 10px;font-size:12px;white-space:pre-wrap;word-break:break-all;';
          dom.textContent = text.replace(/```lua/g, '').replace(/```/g, '').trim().slice(0, 1200);
          return { dom };
        },
      };
    } catch (_) { return null; }
  });
}

// ---------------- Lua 语法折叠 ----------------
// 不能用「按缩进」判定：用户脚本缩进普遍不规范（顶层 end 缩进 4、函数体 return 缩进 0…），
// 按缩进折会出现错位、留下孤儿 end，且每行向后扫描是 O(n²)，大文件卡顿。
// 这里一次全文档扫描（跳过字符串/注释/长括号），用关键字栈配对出所有块，结果与缩进无关。
// 可识别块：function…end / if…then…end / while…do…end / for…do…end / repeat…until / do…end / --[[ 多行注释 ]]
// 规则：块必须跨 ≥2 行，单行的 if/function 不生成折叠标记。
const LUA_OPEN = new Set(['then', 'do', 'repeat', 'function']);
const LUA_CLOSE = new Set(['end', 'until']);
const LUA_MID = new Set(['else', 'elseif']);

// 扫描全文，返回块列表 [{startLine, endLine, depth, comment?}]（行号从 1 开始，depth 0=顶层块）
function scanLuaBlocks(state) {
  const doc = state.doc;
  const text = doc.toString();
  const n = text.length;
  const blocks = [];
  const stack = [];
  let i = 0;
  let pendingElseif = false;   // elseif 后紧跟的 then 是与 elseif 配对的，不新开块

  while (i < n) {
    const c = text[i];

    // 换行
    if (c === '\n') { i++; continue; }

    // 注释
    if (c === '-' && text[i + 1] === '-') {
      i += 2;
      if (text[i] === '[') {           // --[[ 长注释（含 --[==[ 等级别）→ 跨行时生成折叠块
        let eq = 0, j = i + 1;
        while (text[j] === '=') { eq++; j++; }
        if (text[j] === '[') {
          const startOff = i - 2;      // 从 "--" 算起
          const closeStr = ']' + '='.repeat(eq) + ']';
          const k = text.indexOf(closeStr, j + 1);
          const endOff = k < 0 ? n : k + closeStr.length;
          const startLine = doc.lineAt(startOff).number;
          const endLine = doc.lineAt(endOff - 1).number;
          if (endLine > startLine) blocks.push({ startLine, endLine, depth: stack.length, comment: true });
          i = endOff;
          continue;
        }
      }
      const nl = text.indexOf('\n', i);   // 行注释
      i = nl < 0 ? n : nl;
      continue;
    }

    // 字符串 / 长括号
    if (c === '"' || c === "'") {
      const q = c; i++;
      while (i < n) {
        if (text[i] === '\\') { i += 2; continue; }
        if (text[i] === q) { i++; break; }
        if (text[i] === '\n') break;      // Lua 短字符串不能跨行，防御性终止
        i++;
      }
      continue;
    }
    if (c === '[') {
      let eq = 0, j = i + 1;
      while (text[j] === '=') { eq++; j++; }
      if (text[j] === '[') {
        const closeStr = ']' + '='.repeat(eq) + ']';
        const k = text.indexOf(closeStr, j + 1);
        i = k < 0 ? n : k + closeStr.length;
        continue;
      }
    }

    // 标识符 / 关键字
    if (/[A-Za-z_]/.test(c)) {
      let j = i;
      while (j < n && /[A-Za-z0-9_]/.test(text[j])) j++;
      const word = text.slice(i, j);
      i = j;
      // 跳过 t.end / obj:function 这类字段访问（前面是 . 或 :）
      const prev = (text[i - word.length - 1] || '').trim();
      const isField = prev === '.' || prev === ':';
      if (!isField) {
        if (LUA_OPEN.has(word)) {
          if (word === 'then' && pendingElseif) {
            pendingElseif = false;             // elseif ... then 净变化为 0
          } else {
            stack.push({ line: doc.lineAt(i - word.length).number, depth: stack.length });
          }
        } else if (LUA_CLOSE.has(word)) {
          const top = stack.pop();
          if (top) {
            blocks.push({ startLine: top.line, endLine: doc.lineAt(i - word.length).number, depth: top.depth });
          }
          pendingElseif = false;
        } else if (LUA_MID.has(word)) {
          if (word === 'elseif') pendingElseif = true;
        }
      }
      continue;
    }

    i++;
  }
  // 未闭合的块（文件被截断 / 正在编辑中）丢弃，避免折叠到文末
  return blocks;
}

// 缓存：CM6 的 state 不可变，doc 一变 state 就是新对象，据此失效
let _blockCache = { state: null, byLine: null, blocks: null };
function luaBlocks(state) {
  if (_blockCache.state === state) return _blockCache;
  const blocks = scanLuaBlocks(state);
  const byLine = new Map();   // startLine -> endLine（同一行多个块起点时取最外层=endLine 最大）
  for (const b of blocks) {
    if (b.endLine <= b.startLine) continue;   // 单行块不生成折叠标记
    const cur = byLine.get(b.startLine);
    if (!cur || b.endLine > cur) byLine.set(b.startLine, b.endLine);
  }
  _blockCache = { state, byLine, blocks };
  return _blockCache;
}

const luaFoldService = foldService.of((state, lineStart) => {
  const { byLine } = luaBlocks(state);
  const ln = state.doc.lineAt(lineStart).number;
  const endLn = byLine.get(ln);
  if (!endLn) return null;
  const from = state.doc.line(ln).to;
  const to = state.doc.line(endLn).to;
  return to > from ? { from, to } : null;
});

// ---------------- 对外工厂 ----------------
export function createEditor({ parent, doc, getUri, lspUrl, onChange }) {
  let lsp = null;
  let curUri = null;
  let changeTimer = null;

  const lspLint = linter(() => [], { delay: 0 }); // 诊断由 publishDiagnostics 推送注入

  const view = new EditorView({
    parent,
    state: EditorState.create({
      doc: doc || '',
      extensions: [
        lineNumbers(), highlightActiveLine(), highlightActiveLineGutter(), drawSelection(),
        foldGutter({ markerDOM: foldMarkerDOM }), luaFoldService,
        // 对齐原版：折叠后行尾不显示「…」占位框，展开只走 gutter 标记（保留 class 供 edFold 检测折叠态）
        codeFolding({
          placeholderDOM: (view, onclick) => {
            const el = document.createElement('span');
            el.className = 'cm-foldPlaceholder';
            el.onclick = onclick;
            el.title = '展开';
            el.style.cssText = 'display:inline-block;width:0;min-width:0;padding:0;margin:0;cursor:pointer;';
            return el;
          },
        }),
        indentationMarkers({
          markerType: 'fullScope',
          thickness: 1,
          hideFirstIndent: true,
          colors: { dark: '#5a333b', activeDark: '#b04a54' },
        }),
        history(), indentOnInput(), bracketMatching(), closeBrackets(),
        keymap.of([...closeBracketsKeymap, ...defaultKeymap, ...historyKeymap, ...completionKeymap, indentWithTab]),
        StreamLanguage.define(lua),
        syntaxHighlighting(darkHl, { fallback: true }),
        darkTheme,
        autocompletion({ override: [(c) => lspCompletionSource(lsp, () => curUri)(c)], activateOnTyping: true, maxRenderedOptions: 60 }),
        lspHover(() => lsp, () => curUri),
        lspLint, lintGutter(),
        EditorView.updateListener.of((u) => {
          if (u.docChanged) {
            if (onChange) onChange(u.state.doc.toString());
            scheduleSync();
          }
        }),
      ],
    }),
  });

  function scheduleSync() {
    if (!lsp || !lsp.ready || !curUri) return;
    clearTimeout(changeTimer);
    changeTimer = setTimeout(() => {
      lsp.notify('textDocument/didChange', {
        textDocument: { uri: curUri, version: Date.now() },
        contentChanges: [{ text: view.state.doc.toString() }],
      });
    }, 250);
  }

  function openDoc(uri, text) {
    if (!lsp || !lsp.ready) { curUri = uri; return; }
    if (curUri && curUri !== uri) lsp.notify('textDocument/didClose', { textDocument: { uri: curUri } });
    curUri = uri;
    lsp.notify('textDocument/didOpen', {
      textDocument: { uri, languageId: 'lua', version: Date.now(), text },
    });
  }

  // 诊断推送 → CM6 lint（LLS 会把 URI 规范化：盘符小写、冒号编成 %3A，比较前须归一化）
  function bindDiagnostics() {
    const normUri = (u) => {
      try { return decodeURIComponent(new URL(u).pathname).toLowerCase(); } catch (_) { return decodeURIComponent(String(u)).toLowerCase(); }
    };
    lsp.on('textDocument/publishDiagnostics', (p) => {
      if (!p || !curUri || normUri(p.uri) !== normUri(curUri)) return;
      const ds = (p.diagnostics || []).map((d) => ({
        from: posToOffset(view.state.doc, d.range.start),
        to: posToOffset(view.state.doc, d.range.end),
        severity: d.severity === 1 ? 'error' : (d.severity === 2 ? 'warning' : 'info'),
        message: d.message,
        source: d.source || 'lua-ls',
      }));
      view.dispatch(setDiagnostics(view.state, ds));
    });
  }

  return {
    view,
    getDoc: () => view.state.doc.toString(),
    setDoc(text, uri) {
      view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text } });
      openDoc(uri, text);
    },
    async connectLsp(rootUri) {
      lsp = new LspClient(lspUrl);
      await lsp.connect(rootUri);
      bindDiagnostics();
      // 无打开标签页时给默认文档（否则 curUri=null，补全/hover/诊断全部失效）
      if (!curUri) curUri = (rootUri.endsWith('/') ? rootUri : rootUri + '/') + 'untitled.lua';
      openDoc(curUri, view.state.doc.toString());
    },
    get lspReady() { return !!(lsp && lsp.ready); },
    foldAll() {
      // 全部折叠：所有跨≥2行的块全部折起（含顶层 function 与多行注释），每个 function 折成一行。
      // 已实测 CM foldState 允许嵌套范围共存（foldExists 只排斥完全相同范围），
      // 因此无需跳过顶层：外层折叠盖住内层标记，点 ⊞ 展开外层后内层仍是折叠态——正是原版行为。
      const state = view.state;
      const { blocks } = luaBlocks(state);
      if (!blocks.length) return;
      const list = blocks.filter((b) => b.endLine > b.startLine);
      // 外层先折（同起点范围大的优先），保证嵌套 range 有序提交
      list.sort((a, b) => a.startLine - b.startLine || (b.endLine - a.endLine));
      const eff = [];
      for (const b of list) {
        const from = state.doc.line(b.startLine).to;
        const to = state.doc.line(b.endLine).to;
        if (to > from) eff.push(foldEffect.of({ from, to }));
      }
      if (eff.length) view.dispatch({ effects: eff });
    },
    unfoldAll() {
      // 全部展开：对当前折叠集合逐个发 unfoldEffect
      const state = view.state;
      const ds = state.field(foldState, false);
      if (!ds) return;
      const toUnfold = [];
      ds.between(0, state.doc.length, (from, to) => { toUnfold.push({ from, to }); });
      if (toUnfold.length) view.dispatch({ effects: toUnfold.map((r) => unfoldEffect.of(r)) });
    },
    getFoldCount() {
      // 当前折叠数量（比数 DOM placeholder 可靠：隐形占位符在虚拟滚动下可能未渲染）
      const state = view.state;
      const ds = state.field(foldState, false);
      if (!ds) return 0;
      let c = 0;
      ds.between(0, state.doc.length, () => { c++; });
      return c;
    },
    // 语法扫描出的所有可折叠块 [{startLine,endLine,depth}]，1-based，供调试/状态展示
    getFoldRanges() { return luaBlocks(view.state).blocks.slice(); },
    // 当前处于折叠状态的块 [{startLine,endLine}]
    getFolds() {
      const state = view.state;
      const ds = state.field(foldState, false);
      if (!ds) return [];
      const out = [];
      ds.between(0, state.doc.length, (from, to) => {
        out.push({ startLine: state.doc.lineAt(from).number, endLine: state.doc.lineAt(to).number });
      });
      return out;
    },
    toggleFold() {
      // 折叠/展开切换：当前行有折叠则展开，否则折叠可折叠区域（保留原行为作备用）
      cmToggleFold(view);
    },
  };
}
