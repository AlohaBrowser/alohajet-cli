# Tool reference

<!-- GENERATED FILE — do not edit by hand.
     Source: Sources/BrowserTools/Tools/Schemas.swift
     Regenerate: ALOHAJET_REGEN_DOCS=1 swift test --filter ToolsDoc -->

The nine tools alohajet exposes, rendered from the package's own schema registry,
so this page cannot drift from what the MCP server actually advertises. Descriptions
below are the exact text the model is given.

Every tool acts on **the tab in use** — the one `manage_tabs open` or `manage_tabs use`
last selected. Elements are addressed by `aloha-id`, the stable ref a `manage_tabs read`
prints next to each actionable element; see [Stable element refs](../README.md#stable-element-refs).

| tool | reads or writes |
| --- | --- |
| [`manage_tabs`](#managetabs) | drives the page |
| [`page_click`](#pageclick) | drives the page |
| [`page_type`](#pagetype) | drives the page |
| [`page_select`](#pageselect) | drives the page |
| [`get_text`](#gettext) | read-only |
| [`page_navigate`](#pagenavigate) | drives the page |
| [`page_press_keys`](#pagepresskeys) | drives the page |
| [`page_wait_for`](#pagewaitfor) | read-only |
| [`page_upload`](#pageupload) | drives the page |

---

## manage_tabs

`readOnlyHint: false` · `destructiveHint: true` · `openWorldHint: true`

Work with browser tabs. Six actions.

**list** — every open tab: its id, title, URL, and which one is in use.

**read** — returns one tab's page as interactive markdown: headings, lists, links, tables and paragraphs, with every actionable element (link, button, input, select) carrying a trailing {aloha-id="..."} marker. Those ids are what page_click, page_type, page_select and get_text address. A tab that cannot produce interactive markdown (a non-web tab, or one with no attached DOM) falls back to plain markdown with no ids.

**open** — opens a new tab at url AND returns its page in the same result, so one call navigates and reads. Only http and https URLs are accepted. Pass controlled_by: "user" instead when you are handing the user a link to read rather than a page you will drive; that opens an ordinary background tab and returns only its id.

**close** — closes a tab by id. Close the tabs you opened once you are done with them. Only those: a tab that was already open when this session started, or that the user opened, is refused — "list" marks them.

**use** — makes an existing tab the one the page tools address. Exactly one tab is in use at a time; open takes it too, unless you pass use: false.

**unuse** — clears that selection, leaving no tab in use.

Page state is never pushed to you and nothing refreshes a page you have already read: after any click, type or navigation, call read again on that tab to see where it now is.

| parameter | type | required | notes |
| --- | --- | --- | --- |
| `action` | `string` | yes | Which operation to run. one of `list`, `read`, `open`, `close`, `use`, `unuse` |
| `tab_id` | `string` | no | The tab to act on. Required by "read", "close" and "use"; ignored otherwise. |
| `url` | `string` | no | The page to load. Required by "open"; http and https only. |
| `use` | `boolean` | no | Applies to "open". Default true: the new tab becomes the one the page tools address, sparing a separate "use" call. The page comes back in the result either way. Pass false for a batch of opens, or when you do not intend to interact with the page. Ignored when controlled_by is "user". default `true` |
| `controlled_by` | `string` | no | Applies to "open". "agent" (the default) opens a tab this session owns: it is marked agent-controlled, so the host shows its AI indicator and exempts it from background throttling, its network traffic is recorded when the session logs it, and it is taken into use with its page in the result. "user" opens an ordinary background tab instead, exactly as if the user had middle-clicked the link — no indicator, no recording, not taken into use, no page in the result, and close refuses it afterwards because it counts as the user's. Use it for links you are handing the user to read, not pages you intend to drive. one of `agent`, `user`, default `"agent"` |
| `include_screenshot` | `boolean` | no | Applies to "read" and "open". Attaches a viewport screenshot next to the markdown, so layout, modals and anything the markdown cannot express are visible. Costs image tokens. |

---

## page_click

`readOnlyHint: false` · `destructiveHint: true` · `openWorldHint: true`

Click an element on the active tab by its aloha-id. click_type selects single/double/triple/right-click.

| parameter | type | required | notes |
| --- | --- | --- | --- |
| `aloha_id` | `string` | yes | The aloha-id of the element to click. |
| `click_type` | `string` | no | Which kind of click to dispatch. one of `single`, `double`, `triple`, `right`, default `"single"` |

---

## page_type

`readOnlyHint: false` · `destructiveHint: true` · `openWorldHint: true`

Type text into input/textarea/contenteditable elements by aloha-id. To fill a FORM, pass all of its fields in one call as "fields": [{"aloha_id":"7959-1f3a9c2b","text":"..."},{"aloha_id":"7959-7b21e40d","text":"..."}] (up to 20, filled in order) with submit:true to press Enter once at the end — one call instead of one per field. For a single field, pass aloha_id and text directly. One of the two shapes is required: either aloha_id with text, or fields.

| parameter | type | required | notes |
| --- | --- | --- | --- |
| `aloha_id` | `string` | no | The aloha-id of the element to type into. Omit when using "fields". |
| `text` | `string` | no | The text to type. Omit when using "fields". |
| `fields` | `array` of `object` | no | Several fields to fill in one call, in order. Values are taken literally, so text containing commas is safe. If any field fails, the others stay filled and Enter is NOT pressed. min 1 item(s), max 20 items |
| ↳ `aloha_id` | `string` | yes | The aloha-id of the element to type into. |
| ↳ `text` | `string` | yes | The text to type into it. |
| ↳ `replace` | `boolean` | no | Clear this field before typing. Defaults to true. default `true` |
| `replace` | `boolean` | no | Clear the field's existing value before typing. Defaults to true — pass false to append instead. default `true` |
| `submit` | `boolean` | no | Press Enter after typing to submit. With "fields", pressed once after the last field. default `false` |

---

## page_select

`readOnlyHint: false` · `destructiveHint: true` · `openWorldHint: true`

Select an option in a &lt;select&gt; dropdown on the active tab by its aloha-id, matching by visible text or index. At least one of text or index is required.

| parameter | type | required | notes |
| --- | --- | --- | --- |
| `aloha_id` | `string` | yes | The aloha-id of the &lt;select&gt; element. |
| `text` | `string` | no | The visible option text to match. At least one of text/index is required. |
| `index` | `integer` | no | The zero-based option index to match. At least one of text/index is required. min 0 |

---

## get_text

`readOnlyHint: true` · `destructiveHint: false` · `openWorldHint: true`

Read the visible text (or input value) of elements on the active tab by aloha-id. Pass SEVERAL ids at once as a comma-separated list ("7959-1f3a9c2b,7959-7b21e40d,7959-3c8f95a1", up to 20) and each is returned labelled with its id — one call instead of one per element.

| parameter | type | required | notes |
| --- | --- | --- | --- |
| `aloha_id` | `string` | yes | One aloha-id, or several as a comma-separated list ("7959-1f3a9c2b,7959-7b21e40d,7959-3c8f95a1", up to 20 per call). Reading a whole list of rows in one call costs one round instead of one round each. |
| `max_chars` | `integer` | no | Total character budget for the text returned, split evenly across the ids read. A read that hits it is truncated and says so. Raise it deliberately: reading a container element can return an entire page. default `20000`, min 1 |

---

## page_navigate

`readOnlyHint: false` · `destructiveHint: true` · `openWorldHint: true`

Navigate the active tab's current page in place: go to a URL, or go back in history. Unlike manage_tabs' "open" action, this never creates a new tab.

| parameter | type | required | notes |
| --- | --- | --- | --- |
| `action` | `string` | yes | "goto" navigates to url; "back" steps back in history. one of `goto`, `back` |
| `url` | `string` | no | The URL to navigate to. Required when action is "goto"; ignored for "back". http and https only. |

---

## page_press_keys

`readOnlyHint: false` · `destructiveHint: true` · `openWorldHint: true`

Send a keyboard key or chord to whatever currently has focus on the active tab.

| parameter | type | required | notes |
| --- | --- | --- | --- |
| `keys` | `string` | yes | The key or chord to send, e.g. "Enter", "Escape", "Control+a". |

---

## page_wait_for

`readOnlyHint: true` · `destructiveHint: false` · `openWorldHint: true`

Poll the active tab until an element matching a CSS selector appears, or a timeout elapses.

| parameter | type | required | notes |
| --- | --- | --- | --- |
| `selector` | `string` | yes | The CSS selector to wait for. |
| `timeout_ms` | `integer` | no | How long to wait, in milliseconds. Capped at 30000 (30s) — values above the cap are clamped, not rejected. default `10000`, min 0, max 30000 |

---

## page_upload

`readOnlyHint: false` · `destructiveHint: true` · `openWorldHint: true`

Attach files to a file input on the active tab by its aloha-id. This is how you upload: a plain page_click on a [uploadable] element is refused, because it opens a native OS file dialog that is invisible to you and cannot be driven. Paths are read from the machine running this tool, so they must be absolute. If the element has no file &lt;input&gt;, the files are dropped on it instead, which is what a dropzone expects.

| parameter | type | required | notes |
| --- | --- | --- | --- |
| `aloha_id` | `string` | yes | The aloha-id of the [uploadable] file input, or of the dropzone holding it. |
| `paths` | `array` of `string` | yes | Absolute paths of the files to attach, in order. They are read from this machine, not from the page. min 1 item(s) |
