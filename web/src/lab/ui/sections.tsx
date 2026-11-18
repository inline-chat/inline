/** UI lab sections: one per primitive, each state labelled. */

import { signal } from "@inline/reactive"
import { useElement, useModel, useSignal } from "@inline/reactive/react"
import {
  ComboboxController,
  ContextMenuController,
  ListboxController,
  type ListboxOption,
  MenuController,
  type MenuEntry,
  PopoverController,
  SplitViewController,
  TabsController,
  ToggleController,
} from "@inline/ui"
import {
  Avatar,
  Badge,
  Button,
  CheckIcon,
  ChevronIcon,
  CloseIcon,
  Combobox,
  ContextMenuArea,
  Dialog,
  IconButton,
  Kbd,
  LazyMenuContent,
  Listbox,
  MenuButton,
  PopoverContent,
  Progress,
  ScrollArea,
  Separator,
  SplitView,
  Switch,
  Tabs,
  TextField,
  ToastRegion,
  ToggleButton,
} from "@inline/ui/react"
import * as stylex from "@stylexjs/stylex"
import type { ReactNode } from "react"
import { color } from "../../../packages/ui/src/tokens/color.stylex"
import { font } from "../../../packages/ui/src/tokens/font.stylex"
import { radius } from "../../../packages/ui/src/tokens/radius.stylex"
import { space } from "../../../packages/ui/src/tokens/space.stylex"
import { labDialogs, labLazyMenu, labToastAnchor, labToasts, setLabToastAnchor } from "./lab-state"

// MARK: Layout helpers

function Row(props: { children: ReactNode }) {
  return <div {...stylex.props(styles.row)}>{props.children}</div>
}

/** A labelled specimen: the state name above the thing in that state. */
function State(props: { label: string; children: ReactNode; wide?: boolean }) {
  return (
    <figure {...stylex.props(styles.state, props.wide && styles.wide)}>
      <figcaption {...stylex.props(styles.stateLabel)}>{props.label}</figcaption>
      <div {...stylex.props(styles.stateBody)}>{props.children}</div>
    </figure>
  )
}

function Note(props: { children: ReactNode }) {
  return <p {...stylex.props(styles.note)}>{props.children}</p>
}

// MARK: Tokens

const swatches: Array<[string, string]> = [
  ["label", color.label],
  ["secondaryLabel", color.secondaryLabel],
  ["tertiaryLabel", color.tertiaryLabel],
  ["windowBackground", color.windowBackground],
  ["sidebarBackground", color.sidebarBackground],
  ["separator", color.separator],
  ["accent", color.accent],
  ["selectedContentBackground", color.selectedContentBackground],
  ["unemphasizedSelected", color.unemphasizedSelectedContentBackground],
  ["controlHover", color.controlHover],
  ["red", color.red],
  ["orange", color.orange],
  ["green", color.green],
  ["secondaryBubble", color.secondaryBubble],
]

export function TokensSection() {
  return (
    <>
      <Note>Colors follow the page appearance through light-dark(). Names match the macOS semantic colors.</Note>
      <div {...stylex.props(styles.swatches)}>
        {swatches.map(([name, value]) => (
          <div key={name} {...stylex.props(styles.swatch)}>
            <span {...stylex.props(styles.swatchColor, dynamic.background(value))} />
            <span {...stylex.props(styles.swatchName)}>{name}</span>
          </div>
        ))}
      </div>
      <div {...stylex.props(styles.typeScale)}>
        <span {...stylex.props(typeStyles.largeTitle)}>Large title 26</span>
        <span {...stylex.props(typeStyles.title1)}>Title 1 22</span>
        <span {...stylex.props(typeStyles.title2)}>Title 2 17</span>
        <span {...stylex.props(typeStyles.title3)}>Title 3 15</span>
        <span {...stylex.props(typeStyles.headline)}>Headline 13</span>
        <span>Body 13: The quick brown fox jumps over the lazy dog. שלום عربى</span>
        <span {...stylex.props(typeStyles.callout)}>Callout 12</span>
        <span {...stylex.props(typeStyles.subheadline)}>Subheadline 11</span>
        <span {...stylex.props(typeStyles.mono)}>Monospace 13: const x = 42</span>
      </div>
    </>
  )
}

// MARK: Buttons

export function ButtonsSection() {
  const [count, setCount] = useCounter()
  return (
    <>
      <Row>
        <State label="Primary">
          <Button variant="primary" onClick={setCount}>
            Send
          </Button>
        </State>
        <State label="Secondary">
          <Button>Cancel</Button>
        </State>
        <State label="Plain">
          <Button variant="plain">More</Button>
        </State>
        <State label="Destructive">
          <Button variant="destructive">Delete</Button>
        </State>
        <State label="With icon">
          <Button icon={<CheckIcon size={14} />}>Done</Button>
        </State>
        <State label="Disabled">
          <Button variant="primary" disabled>
            Send
          </Button>
        </State>
      </Row>
      <Row>
        <State label="Small">
          <Button size="small">Small</Button>
        </State>
        <State label="Regular">
          <Button>Regular</Button>
        </State>
        <State label="Large">
          <Button size="large" variant="primary">
            Large
          </Button>
        </State>
        <State label={`Clicks on primary: ${count}`}>
          <span />
        </State>
      </Row>
      <Note>IconButton: hover for the tooltip (600 ms, then neighbors open at once); Tab to one for an instant tooltip.</Note>
      <Row>
        <State label="Icon buttons (tooltip group)">
          <IconButton label="Close" icon={<CloseIcon />} />
          <IconButton label="Done" icon={<CheckIcon />} />
          <IconButton label="Next" icon={<ChevronIcon />} />
        </State>
        <State label="Pressed">
          <IconButton label="Bold" icon={<CheckIcon />} pressed />
        </State>
        <State label="Disabled">
          <IconButton label="Unavailable" icon={<CloseIcon />} disabled />
        </State>
        <State label="Small and large">
          <IconButton label="Small" size="small" icon={<CloseIcon size={12} />} />
          <IconButton label="Large" size="large" icon={<CloseIcon size={18} />} />
        </State>
      </Row>
    </>
  )
}

/** Lab-only local counter; a tuple keeps call sites short. */
function useCounter(): [number, () => void] {
  const model = useModel(() => signal(0))
  const value = useSignal(model)
  return [value, () => model.update((current) => current + 1)]
}

// MARK: Fields

export function FieldsSection() {
  return (
    <Row>
      <State label="Default" wide>
        <TextField label="Chat name" placeholder="Design review" />
      </State>
      <State label="With description" wide>
        <TextField label="Username" defaultValue="ada" description="Letters, numbers and underscores." />
      </State>
      <State label="Error" wide>
        <TextField label="Email" defaultValue="ada@" error="Enter a full email address." />
      </State>
      <State label="Disabled" wide>
        <TextField label="Workspace" defaultValue="Inline" disabled />
      </State>
      <State label="Hidden label, right-to-left text" wide>
        <TextField label="Search" hideLabel placeholder="Search" defaultValue="שלום world" />
      </State>
    </Row>
  )
}

// MARK: Display

const names = ["Ada Lovelace", "Alan Turing", "Grace Hopper", "Linus", "محمد علي", "👩🏽‍💻 Dev", "Édith Piaf"]

export function DisplaySection() {
  return (
    <>
      <Row>
        <State label="Kbd">
          <Kbd keys={["⌘", "K"]} label="Command K" />
          <Kbd keys={["Ctrl", "Shift", "P"]} />
          <Kbd keys={["Esc"]} />
        </State>
        <State label="Badge tones">
          <Badge count={3} />
          <Badge count={12} tone="accent" />
          <Badge count={250} tone="danger" label="250 unread" />
          <Badge tone="success">New</Badge>
          <Badge tone="warning">Beta</Badge>
        </State>
      </Row>
      <Row>
        <State label="Avatar sizes">
          <Avatar name="Ada Lovelace" size="small" />
          <Avatar name="Ada Lovelace" />
          <Avatar name="Ada Lovelace" size="large" />
        </State>
        <State label="Avatar colors (same palette and hash as the Apple apps)">
          {names.map((name) => (
            <Avatar key={name} name={name} />
          ))}
        </State>
      </Row>
      <Row>
        <State label="Progress 0%" wide>
          <Progress value={0} label="Upload" />
        </State>
        <State label="Progress 40%" wide>
          <Progress value={0.4} label="Upload" />
        </State>
        <State label="Progress 100%" wide>
          <Progress value={1} label="Upload" />
        </State>
        <State label="Indeterminate" wide>
          <Progress label="Syncing" />
        </State>
        <State label="Spinner">
          <Progress label="Loading" variant="spinner" />
        </State>
      </Row>
      <Row>
        <State label="Separators">
          <div {...stylex.props(styles.separatorDemo)}>
            <span>One</span>
            <Separator orientation="vertical" />
            <span>Two</span>
          </div>
        </State>
        <State label="ScrollArea (focusable, thin scrollbars)" wide>
          <ScrollArea label="Scrollable list" style={styles.scrollDemo}>
            {Array.from({ length: 30 }, (_, index) => (
              <div key={index} {...stylex.props(styles.scrollItem)}>
                Row {index + 1}
              </div>
            ))}
          </ScrollArea>
        </State>
      </Row>
    </>
  )
}

// MARK: Menus

const useMenuState = () =>
  useModel(() => ({
    bold: signal(true),
    wrap: signal(false),
    size: signal("medium"),
    last: signal("nothing yet"),
  }))

const editMenuEntries = (state: ReturnType<typeof useMenuState>): MenuEntry[] => [
  { type: "item", id: "undo", label: "Undo", shortcut: "⌘Z", onSelect: () => state.last.set("Undo") },
  { type: "item", id: "redo", label: "Redo", shortcut: "⇧⌘Z", disabled: true },
  { type: "separator", id: "s1" },
  { type: "item", id: "cut", label: "Cut", shortcut: "⌘X", onSelect: () => state.last.set("Cut") },
  { type: "item", id: "copy", label: "Copy", shortcut: "⌘C", onSelect: () => state.last.set("Copy") },
  { type: "item", id: "paste", label: "Paste", shortcut: "⌘V", onSelect: () => state.last.set("Paste") },
  { type: "separator", id: "s2" },
  {
    type: "checkbox",
    id: "bold",
    label: "Bold",
    checked: state.bold.get(),
    onCheckedChange: (checked) => state.bold.set(checked),
  },
  {
    type: "checkbox",
    id: "wrap",
    label: "Wrap lines (stays open)",
    checked: state.wrap.get(),
    keepOpen: true,
    onCheckedChange: (checked) => state.wrap.set(checked),
  },
  {
    type: "submenu",
    id: "size",
    label: "Text size",
    items: () =>
      (["small", "medium", "large"] as const).map((size) => ({
        type: "radio" as const,
        id: size,
        label: size[0]!.toUpperCase() + size.slice(1),
        checked: state.size.get() === size,
        onSelect: () => state.size.set(size),
      })),
  },
  {
    type: "submenu",
    id: "share",
    label: "Share",
    items: [
      { type: "label", id: "share-heading", label: "Send to" },
      { type: "item", id: "copylink", label: "Copy link", onSelect: () => state.last.set("Copy link") },
      {
        type: "submenu",
        id: "apps",
        label: "Apps",
        items: [
          { type: "item", id: "mail", label: "Mail", onSelect: () => state.last.set("Mail") },
          { type: "item", id: "notes", label: "Notes", onSelect: () => state.last.set("Notes") },
        ],
      },
    ],
  },
  { type: "separator", id: "s3" },
  { type: "item", id: "delete", label: "Delete", destructive: true, onSelect: () => state.last.set("Delete") },
]

export function MenusSection() {
  const state = useMenuState()
  const menu = useModel(() => new MenuController({ items: () => editMenuEntries(state) }))
  const context = useModel(
    () =>
      new ContextMenuController({
        label: "Message actions",
        items: [
          { type: "item", id: "reply", label: "Reply", shortcut: "R", onSelect: () => state.last.set("Reply") },
          { type: "item", id: "react", label: "Add reaction", onSelect: () => state.last.set("Add reaction") },
          { type: "separator", id: "s" },
          { type: "item", id: "copytext", label: "Copy text", onSelect: () => state.last.set("Copy text") },
          { type: "item", id: "remove", label: "Delete message", destructive: true, onSelect: () => state.last.set("Delete") },
        ],
      }),
  )
  const last = useSignal(state.last)
  return (
    <>
      <Note>
        Keyboard: focus the button, press Enter or ↓ (first item) or ↑ (last item). ↑ ↓ Home End move, type letters to jump,
        → opens a submenu, ← or Esc closes one level, Tab closes. Pointer: hover over Text size and move diagonally into it;
        crossing Share on the way keeps the submenu open (safe triangle).
      </Note>
      <Row>
        <State label="Menu button with checkboxes, radios, nested submenus, disabled and destructive items">
          <MenuButton menu={menu}>Edit</MenuButton>
        </State>
        <State label="Last action">
          <span>{last}</span>
        </State>
      </Row>
      <State label="Context menu: right-click, long-press, or focus the area and press Shift+F10 or the menu key" wide>
        <ContextMenuArea controller={context} style={styles.contextArea}>
          <div tabIndex={0} {...stylex.props(styles.contextTarget)}>
            Right-click this message
          </div>
        </ContextMenuArea>
      </State>
      <State
        label="Lazy context menu: the menu's code loads on the first request (delay set by __uiLabControl.setLazyMenuDelay); the browser's menu never shows meanwhile"
        wide
      >
        <LazyMenuArea />
      </State>
    </>
  )
}

function LazyMenuArea() {
  const target = useElement(labLazyMenu.target)
  const waiting = useSignal(labLazyMenu.waiting)
  return (
    <div ref={target} {...stylex.props(styles.contextArea)}>
      <div tabIndex={0} data-lab-lazy-target="" aria-busy={waiting || undefined} {...stylex.props(styles.contextTarget)}>
        {waiting ? "Loading the menu…" : "Right-click this row (lazy menu)"}
      </div>
      <LazyMenuContent menu={labLazyMenu} />
    </div>
  )
}

// MARK: Overlays

export function OverlaysSection() {
  const popover = useModel(() => new PopoverController({ label: "Chat info", placement: "bottom", arrowSize: 10 }))
  const plainPopover = useModel(() => new PopoverController({ label: "Filters", placement: "bottom-start" }))
  const { dialog, alert, sheet, long } = labDialogs
  const unreadOnly = useModel(() => new ToggleController({ kind: "switch", pressed: true }))
  const mentions = useModel(() => new ToggleController({ kind: "switch" }))
  const popoverTrigger = useElement(popover.trigger)
  const plainTrigger = useElement(plainPopover.trigger)
  return (
    <>
      <Note>
        Popovers close on Esc, an outside click, or focus leaving, and return focus to their button. Dialogs trap Tab, make
        the page inert, and close on Esc; a dialog also closes on a backdrop click, a sheet and an alert do not.
      </Note>
      <Row>
        <State label="Popover with arrow">
          <Button ref={popoverTrigger}>Chat info</Button>
          <PopoverContent controller={popover} arrow>
            <div {...stylex.props(styles.popoverBody)}>
              <strong>Design review</strong>
              <span {...stylex.props(styles.muted)}>12 members · created by Ada</span>
              <TextField label="Topic" defaultValue="Weekly sync" />
              <Button variant="primary" onClick={() => popover.close()}>
                Save
              </Button>
            </div>
          </PopoverContent>
        </State>
        <State label="Popover without arrow">
          <Button ref={plainTrigger}>Filters</Button>
          <PopoverContent controller={plainPopover}>
            <div {...stylex.props(styles.popoverBody)}>
              <Switch controller={unreadOnly} label="Unread only" />
              <Switch controller={mentions} label="Mentions" />
            </div>
          </PopoverContent>
        </State>
        <State label="Dialog">
          <Button onClick={() => dialog.open()}>Rename chat…</Button>
        </State>
        <State label="Alert dialog">
          <Button variant="destructive" onClick={() => alert.open()}>
            Delete chat…
          </Button>
        </State>
        <State label="Sheet">
          <Button onClick={() => sheet.open()}>New thread…</Button>
        </State>
        <State label="Long content: scrolls inside, never taller than the window (try a narrow window)">
          <Button onClick={() => long.open()}>Terms…</Button>
        </State>
      </Row>
      <Dialog
        controller={dialog}
        title="Rename chat"
        description="Everyone in the chat will see the new name."
        footer={
          <>
            <Button onClick={() => dialog.close("button")}>Cancel</Button>
            <Button variant="primary" onClick={() => dialog.close("action")}>
              Rename
            </Button>
          </>
        }
      >
        <TextField label="Name" defaultValue="Design review" />
      </Dialog>
      <Dialog
        controller={alert}
        title="Delete this chat?"
        description="Messages are deleted for everyone. This cannot be undone."
        closeButton={false}
        footer={
          <>
            <Button onClick={() => alert.close("button")}>Cancel</Button>
            <Button variant="destructive" onClick={() => alert.close("action")}>
              Delete
            </Button>
          </>
        }
      />
      <Dialog
        controller={sheet}
        title="New thread"
        footer={
          <>
            <Button onClick={() => sheet.close("button")}>Cancel</Button>
            <Button variant="primary" onClick={() => sheet.close("action")}>
              Create
            </Button>
          </>
        }
      >
        <TextField label="Title" placeholder="What is this thread about?" />
      </Dialog>
      <Dialog
        controller={long}
        title="Workspace terms with a long title that wraps at narrow widths"
        description="Read to the end. The header and the buttons stay put; this part scrolls."
        footer={
          <>
            <Button onClick={() => long.close("button")}>Decline</Button>
            <Button variant="primary" onClick={() => long.close("action")}>
              Accept
            </Button>
          </>
        }
      >
        {Array.from({ length: 40 }, (_, index) => (
          <p key={index} {...stylex.props(styles.paragraph)}>
            {index + 1}. Messages, files and reactions in this workspace are visible to its members. Admins can export them.
          </p>
        ))}
      </Dialog>
    </>
  )
}

// MARK: Collections

const folders: ListboxOption[] = [
  { id: "inbox", label: "Inbox" },
  { id: "mentions", label: "Mentions" },
  { id: "drafts", label: "Drafts", disabled: true },
  { id: "archive", label: "Archive" },
  { id: "saved", label: "Saved" },
  { id: "spam", label: "Spam" },
]

const people: ListboxOption[] = [
  "Ada Lovelace",
  "Alan Turing",
  "Barbara Liskov",
  "Edsger Dijkstra",
  "Grace Hopper",
  "Katherine Johnson",
  "Ken Thompson",
  "Margaret Hamilton",
  "محمد الخوارزمي",
].map((label) => ({ id: label.toLowerCase().replace(/\s+/g, "-"), label }))

/** Simulated server search, so the async path shows loading and stale-result handling. */
const searchPeople = (query: string, abort: AbortSignal): Promise<readonly ListboxOption[]> =>
  new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      if (query.toLowerCase() === "error") reject(new Error("Simulated failure"))
      else resolve(people.filter((person) => person.label.toLowerCase().includes(query.toLowerCase())))
    }, 400)
    abort.addEventListener("abort", () => clearTimeout(timer))
  })

export function CollectionsSection() {
  const single = useModel(() => new ListboxController({ items: () => folders, label: "Folder", selected: ["inbox"] }))
  const multiple = useModel(
    () => new ListboxController({ items: () => folders, label: "Folders to sync", selectionMode: "multiple", selected: ["inbox", "saved"] }),
  )
  const local = useModel(() => new ComboboxController({ items: () => people, label: "People", openOnFocus: true }))
  const remote = useModel(() => new ComboboxController({ load: searchPeople, debounce: 150, label: "Search people", selectionMode: "multiple" }))
  const tabs = useModel(() => new TabsController({ tabs: () => [{ id: "general" }, { id: "notifications" }, { id: "privacy", disabled: true }, { id: "advanced" }], label: "Settings" }))
  const manualTabs = useModel(() => new TabsController({ tabs: () => [{ id: "one" }, { id: "two" }, { id: "three" }], activation: "manual", label: "Manual" }))
  const singleSelected = useSignal(single.selected)
  const multipleSelected = useSignal(multiple.selected)
  return (
    <>
      <Note>
        Listbox: ↑ ↓ move the selection; in the multiple list Shift+↑↓ and Shift+click extend, ⌘-click (Ctrl elsewhere)
        toggles, ⌘A selects all. Combobox: type to filter; ↓ ↑ move, Enter commits, Esc closes then clears. Type “error”
        in the async one to see the failure state.
      </Note>
      <Row>
        <State label={`Single: ${[...singleSelected].join(", ")}`}>
          <Listbox controller={single} style={styles.listbox} />
        </State>
        <State label={`Multiple: ${[...multipleSelected].join(", ")}`}>
          <Listbox controller={multiple} style={styles.listbox} />
        </State>
        <State label="Combobox, local filter" wide>
          <Combobox controller={local} label="Person" placeholder="Find a person" />
        </State>
        <State label="Combobox, async with multiple selection" wide>
          <Combobox controller={remote} label="Search people" placeholder="Search (simulated 400 ms)" />
        </State>
      </Row>
      <Row>
        <State label="Tabs, automatic activation (Privacy is disabled)" wide>
          <Tabs
            controller={tabs}
            tabs={[
              { id: "general", label: "General" },
              { id: "notifications", label: "Notifications" },
              { id: "privacy", label: "Privacy" },
              { id: "advanced", label: "Advanced" },
            ]}
            renderPanel={(id) => <p {...stylex.props(styles.panelText)}>Panel: {id}</p>}
          />
        </State>
        <State label="Tabs, manual activation (arrows move, Enter selects)" wide>
          <Tabs
            controller={manualTabs}
            tabs={[
              { id: "one", label: "One" },
              { id: "two", label: "Two" },
              { id: "three", label: "Three" },
            ]}
            renderPanel={(id) => <p {...stylex.props(styles.panelText)}>Panel: {id}</p>}
          />
        </State>
      </Row>
    </>
  )
}

// MARK: Controls

export function ControlsSection() {
  const bold = useModel(() => new ToggleController())
  const italic = useModel(() => new ToggleController({ pressed: true }))
  const on = useModel(() => new ToggleController({ kind: "switch", pressed: true }))
  const off = useModel(() => new ToggleController({ kind: "switch" }))
  const disabled = useModel(() => new ToggleController({ kind: "switch", disabled: true }))
  return (
    <Row>
      <State label="Toggle off">
        <ToggleButton controller={bold}>Bold</ToggleButton>
      </State>
      <State label="Toggle on">
        <ToggleButton controller={italic}>Italic</ToggleButton>
      </State>
      <State label="Switch on">
        <Switch controller={on} label="Notifications" />
      </State>
      <State label="Switch off">
        <Switch controller={off} label="Sounds" />
      </State>
      <State label="Switch disabled">
        <Switch controller={disabled} label="Beta features" />
      </State>
    </Row>
  )
}

// MARK: Split view

export function SplitSection() {
  const state = useModel(() => signal("{}"))
  const split = useModel(
    () =>
      new SplitViewController({
        panes: [
          { id: "sidebar", size: 220, minSize: 160, maxSize: 320, collapsible: true, label: "Sidebar" },
          { id: "main", flex: true, minSize: 200 },
          { id: "inspector", size: 200, minSize: 160, maxSize: 300, label: "Inspector" },
        ],
        onChange: (next) => state.set(JSON.stringify(next)),
      }),
  )
  const persisted = useSignal(state)
  return (
    <>
      <Note>
        Drag a divider, or Tab to it and use ← → (Shift for bigger steps), Home, End, and Enter to collapse. Drag the
        sidebar below half its minimum to collapse it; double-click a divider to toggle.
      </Note>
      <div {...stylex.props(styles.splitFrame)}>
        <SplitView
          controller={split}
          panes={[
            { id: "sidebar", content: <div {...stylex.props(styles.pane, styles.sidebarPane)}>Sidebar</div> },
            { id: "main", content: <div {...stylex.props(styles.pane)}>Main (flexible)</div> },
            { id: "inspector", content: <div {...stylex.props(styles.pane, styles.sidebarPane)}>Inspector</div> },
          ]}
        />
      </div>
      <State label="Persisted state (plain data, written on release)" wide>
        <code {...stylex.props(styles.code)}>{persisted}</code>
      </State>
    </>
  )
}

// MARK: Toast

export function ToastSection() {
  const queue = labToasts
  const anchor = useSignal(labToastAnchor)
  return (
    <>
      <Note>
        Three show at once; the rest wait. Hovering or focusing a toast pauses every timer. The app places the region: by
        default the window's inline-end, block-end corner; anchored, the corner of the box below (__uiLabControl.setToastAnchor).
      </Note>
      <Row>
        <Button onClick={() => queue.show({ title: "Message sent" })}>Neutral</Button>
        <Button onClick={() => queue.show({ title: "Saved", description: "Your changes are synced.", tone: "success" })}>
          Success
        </Button>
        <Button onClick={() => queue.show({ title: "Offline", description: "We will retry when you are back.", tone: "warning" })}>
          Warning
        </Button>
        <Button
          onClick={() =>
            queue.show({
              title: "Could not upload photo.png",
              tone: "error",
              duration: Infinity,
              action: { label: "Retry", onAction: () => queue.show({ title: "Retrying…" }) },
            })
          }
        >
          Sticky error with action
        </Button>
        <Button
          onClick={() =>
            queue.show({
              title: "Bot button",
              description:
                "Runs “Deploy to production” as Release Bot: it can post in this chat and read the last 50 messages. A long description wraps and is read once.",
              duration: Infinity,
            })
          }
        >
          Long description
        </Button>
        <Button
          onClick={() => {
            const id = queue.show({ title: "Uploading…", duration: Infinity })
            setTimeout(() => queue.show({ id, title: "Uploaded", tone: "success" }), 1500)
          }}
        >
          Replace in place
        </Button>
        <Button variant="plain" onClick={() => queue.clear()}>
          Clear all
        </Button>
      </Row>
      <Row>
        <Button aria-pressed={anchor === "window"} onClick={() => setLabToastAnchor("window")}>
          Window corner
        </Button>
        <Button aria-pressed={anchor === "container"} onClick={() => setLabToastAnchor("container")}>
          Container corner
        </Button>
      </Row>
      {anchor === "container" ? <AnchoredToastBox /> : <div data-lab-toast-container="" {...stylex.props(styles.toastBox)} />}
      <ToastRegion queue={queue} />
    </>
  )
}

/** A message list stand-in: the toasts sit in its inline-end, block-end corner while it is the queue's container. */
function AnchoredToastBox() {
  const ref = useElement(labToasts.container)
  return (
    <div ref={ref} data-lab-toast-container="" {...stylex.props(styles.toastBox, styles.toastBoxAnchored)}>
      Toasts sit in this box's inline-end, block-end corner, 12 px in.
    </div>
  )
}

// MARK: Styles

const styles = stylex.create({
  row: { display: "flex", flexWrap: "wrap", alignItems: "flex-start", gap: space.xl },
  state: {
    display: "flex",
    flexDirection: "column",
    gap: space.sm,
    margin: 0,
    minWidth: 0,
  },
  wide: { flexBasis: "260px", flexGrow: 1 },
  stateLabel: { fontSize: font.sizeSubheadline, color: color.secondaryLabel, textTransform: "uppercase", letterSpacing: "0.04em" },
  stateBody: { display: "flex", flexWrap: "wrap", alignItems: "center", gap: space.md },
  note: { margin: 0, color: color.secondaryLabel, maxWidth: "70ch" },
  swatches: { display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(150px, 1fr))", gap: space.md },
  swatch: { display: "flex", alignItems: "center", gap: space.md },
  swatchColor: {
    width: "28px",
    height: "28px",
    borderRadius: radius.control,
    boxShadow: `inset 0 0 0 1px ${color.separator}`,
    flexShrink: 0,
  },
  swatchName: { fontSize: font.sizeCallout, color: color.secondaryLabel },
  typeScale: { display: "flex", flexDirection: "column", gap: space.xs },
  separatorDemo: { display: "flex", alignItems: "center", gap: space.md, height: "24px" },
  scrollDemo: { height: "120px", width: "100%", borderRadius: radius.control, boxShadow: `inset 0 0 0 1px ${color.separator}` },
  scrollItem: { paddingBlock: space.xs, paddingInline: space.md },
  contextArea: { display: "block" },
  contextTarget: {
    padding: space.lg,
    borderRadius: radius.bubble,
    backgroundColor: color.secondaryBubble,
    color: color.secondaryBubbleText,
    maxWidth: "320px",
    outline: { default: "none", ":focus-visible": `3px solid ${color.focusRing}` },
  },
  popoverBody: { display: "flex", flexDirection: "column", gap: space.md, minWidth: "240px" },
  muted: { color: color.secondaryLabel, fontSize: font.sizeCallout },
  listbox: { width: "200px", maxHeight: "200px" },
  panelText: { margin: 0, padding: space.md, color: color.secondaryLabel },
  splitFrame: {
    height: "220px",
    borderRadius: radius.content,
    overflow: "hidden",
    boxShadow: `inset 0 0 0 1px ${color.separator}`,
  },
  pane: { display: "flex", alignItems: "center", justifyContent: "center", height: "100%", color: color.secondaryLabel },
  sidebarPane: { backgroundColor: color.sidebarBackground },
  code: { fontFamily: font.familyMono, fontSize: font.sizeCallout, overflowWrap: "anywhere" },
  paragraph: { margin: 0 },
  toastBox: {
    blockSize: "220px",
    padding: space.lg,
    borderRadius: radius.content,
    boxShadow: `inset 0 0 0 1px ${color.separator}`,
    color: color.secondaryLabel,
  },
  toastBoxAnchored: { boxShadow: `inset 0 0 0 2px ${color.accent}` },
})

const typeStyles = stylex.create({
  largeTitle: { fontSize: font.sizeLargeTitle, fontWeight: font.weightBold },
  title1: { fontSize: font.sizeTitle1, fontWeight: font.weightBold },
  title2: { fontSize: font.sizeTitle2, fontWeight: font.weightSemibold },
  title3: { fontSize: font.sizeTitle3, fontWeight: font.weightSemibold },
  headline: { fontSize: font.sizeHeadline, fontWeight: font.weightSemibold },
  callout: { fontSize: font.sizeCallout },
  subheadline: { fontSize: font.sizeSubheadline },
  mono: { fontFamily: font.familyMono },
})

const dynamic = stylex.create({
  background: (value: string) => ({ backgroundColor: value }),
})
