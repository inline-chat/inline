import { DirectionProvider } from "@base-ui/react/direction-provider"
import { Select } from "@base-ui/react/select"
import { Toggle } from "@base-ui/react/toggle"
import { ToggleGroup } from "@base-ui/react/toggle-group"
import * as stylex from "@stylexjs/stylex"
import type { ReactNode } from "react"
import {
  directionForLocale,
  locales,
  type Locale,
  type ThemePreference,
} from "./preferences"
import { darkTheme, landingColors, lightTheme } from "./tokens.stylex"

type Copy = {
  preferences: string
  language: string
  appearance: string
  system: string
  light: string
  dark: string
}

type Props = {
  locale: Locale
  theme: ThemePreference
  copy: Copy
  onLocaleChange: (locale: Locale) => void
  onThemeChange: (theme: ThemePreference) => void
}

const localeItems = locales.map(({ code, name }) => ({ value: code, label: name }))

export function LandingPreferences({ locale, theme, copy, onLocaleChange, onThemeChange }: Props) {
  const direction = directionForLocale(locale)

  return (
    <DirectionProvider direction={direction}>
      <section
        aria-label={copy.preferences}
        {...stylex.props(
          styles.preferences,
          locale === "en" && styles.englishInterfaceFont,
          locale === "fa" && styles.persianFont,
        )}
      >
        <Select.Root
          items={localeItems}
          value={locale}
          onValueChange={(value) => value && onLocaleChange(value as Locale)}
        >
          <Select.Label {...stylex.props(styles.visuallyHidden)}>{copy.language}</Select.Label>
          <Select.Trigger {...stylex.props(styles.languageTrigger)}>
            <GlobeIcon />
            <Select.Value {...stylex.props(styles.languageValue)} />
            <Select.Icon className={(state) => stylex.props(styles.chevron, state.open && styles.openChevron).className}>
              <ChevronDownIcon />
            </Select.Icon>
          </Select.Trigger>

          <Select.Portal>
            <Select.Positioner
              sideOffset={7}
              align="start"
              alignItemWithTrigger={false}
              {...stylex.props(
                styles.selectPositioner,
                theme === "light" && lightTheme,
                theme === "dark" && darkTheme,
              )}
            >
              <Select.Popup
                className={(state) =>
                  stylex.props(
                    styles.selectPopup,
                    locale === "en" && styles.englishInterfaceFont,
                    locale === "fa" && styles.persianFont,
                    state.transitionStatus === "starting" && styles.popupStarting,
                    state.transitionStatus === "ending" && styles.popupEnding,
                  ).className
                }
              >
                <Select.List {...stylex.props(styles.selectList)}>
                  {locales.map((option) => (
                    <Select.Item
                      key={option.code}
                      value={option.code}
                      className={(state) =>
                        stylex.props(
                          styles.selectItem,
                          state.highlighted && styles.highlightedItem,
                          state.selected && styles.selectedItem,
                        ).className
                      }
                    >
                      <span {...stylex.props(styles.indicatorSlot)}>
                        <Select.ItemIndicator {...stylex.props(styles.itemIndicator)}>
                          <CheckIcon />
                        </Select.ItemIndicator>
                      </span>
                      <Select.ItemText>
                        <span
                          lang={option.code}
                          dir={directionForLocale(option.code)}
                          {...stylex.props(
                            styles.itemText,
                            locale !== "fa" && option.code === "en" && styles.englishInterfaceFont,
                            option.code === "fa" && styles.persianFont,
                            locale !== "fa" &&
                              option.code !== "en" &&
                              option.code !== "fa" &&
                              styles.nativeFont,
                          )}
                        >
                          {option.name}
                        </span>
                      </Select.ItemText>
                    </Select.Item>
                  ))}
                </Select.List>
              </Select.Popup>
            </Select.Positioner>
          </Select.Portal>
        </Select.Root>

        <ToggleGroup
          aria-label={copy.appearance}
          value={[theme]}
          onValueChange={(values) => {
            const value = values[0] as ThemePreference | undefined
            if (value) onThemeChange(value)
          }}
          {...stylex.props(styles.themePicker)}
        >
          <ThemeToggle value="system" label={copy.system} icon={<SystemIcon />} />
          <ThemeToggle value="light" label={copy.light} icon={<SunIcon />} />
          <ThemeToggle value="dark" label={copy.dark} icon={<MoonIcon />} />
        </ToggleGroup>
      </section>
    </DirectionProvider>
  )
}

function ThemeToggle({ value, label, icon }: { value: ThemePreference; label: string; icon: ReactNode }) {
  return (
    <Toggle
      value={value}
      aria-label={label}
      title={label}
      className={(state) => stylex.props(styles.themeOption, state.pressed && styles.selectedThemeOption).className}
    >
      {icon}
    </Toggle>
  )
}

function GlobeIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 20 20" {...stylex.props(styles.icon)}>
      <circle cx="10" cy="10" r="7.25" />
      <path d="M2.9 10h14.2M10 2.75c2 2.05 3.05 4.47 3.05 7.25S12 15.2 10 17.25C8 15.2 6.95 12.78 6.95 10S8 4.8 10 2.75Z" />
    </svg>
  )
}

function ChevronDownIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 16 16" {...stylex.props(styles.smallIcon)}>
      <path d="m4.25 6.25 3.75 3.5 3.75-3.5" />
    </svg>
  )
}

function CheckIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 16 16" {...stylex.props(styles.smallIcon)}>
      <path d="m3.25 8.25 3 3 6.5-6.5" />
    </svg>
  )
}

function SystemIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 20 20" {...stylex.props(styles.themeIcon)}>
      <rect x="3" y="3.5" width="14" height="10" rx="1.8" />
      <path d="M7 16.5h6M10 13.5v3" />
    </svg>
  )
}

function SunIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 20 20" {...stylex.props(styles.themeIcon)}>
      <circle cx="10" cy="10" r="3.25" />
      <path d="M10 2v1.5M10 16.5V18M2 10h1.5M16.5 10H18M4.35 4.35l1.05 1.05M14.6 14.6l1.05 1.05M15.65 4.35 14.6 5.4M5.4 14.6l-1.05 1.05" />
    </svg>
  )
}

function MoonIcon() {
  return (
    <svg aria-hidden="true" viewBox="0 0 20 20" {...stylex.props(styles.themeIcon)}>
      <path d="M16.75 12.35A7.25 7.25 0 0 1 7.65 3.25a7.25 7.25 0 1 0 9.1 9.1Z" />
    </svg>
  )
}

const styles = stylex.create({
  preferences: {
    width: "100%",
    maxWidth: 1200,
    marginInline: "auto",
    paddingTop: 18,
    paddingBottom: "max(18px, env(safe-area-inset-bottom))",
    paddingInline: { default: 16, "@media (min-width: 640px)": 32 },
    borderTopWidth: 1,
    borderTopStyle: "solid",
    borderTopColor: landingColors.border,
    display: "flex",
    alignItems: "center",
    justifyContent: "flex-end",
    gap: 10,
  },
  visuallyHidden: {
    position: "absolute",
    width: 1,
    height: 1,
    padding: 0,
    margin: -1,
    overflow: "hidden",
    clip: "rect(0, 0, 0, 0)",
    whiteSpace: "nowrap",
  },
  languageTrigger: {
    minWidth: { default: 0, "@media (min-width: 480px)": 174 },
    maxWidth: 210,
    flexGrow: { default: 1, "@media (min-width: 480px)": 0 },
    height: 38,
    paddingInline: 11,
    borderRadius: 10,
    backgroundColor: landingColors.control,
    color: landingColors.secondaryText,
    display: "flex",
    alignItems: "center",
    gap: 8,
    cursor: "pointer",
    outline: "none",
    transitionProperty: "background-color, color, box-shadow",
    transitionDuration: "140ms",
    ":hover": {
      backgroundColor: landingColors.controlHover,
      color: landingColors.text,
    },
    ":focus-visible": {
      outlineWidth: 2,
      outlineStyle: "solid",
      outlineColor: landingColors.focus,
      outlineOffset: 2,
    },
  },
  languageValue: {
    minWidth: 0,
    flexGrow: 1,
    overflow: "hidden",
    textOverflow: "ellipsis",
    color: landingColors.text,
    fontSize: 13,
    fontWeight: 500,
    lineHeight: 1,
    whiteSpace: "nowrap",
    textAlign: "start",
  },
  chevron: {
    display: "flex",
    color: landingColors.secondaryText,
    transitionProperty: "transform",
    transitionDuration: "140ms",
  },
  openChevron: {
    transform: "rotate(180deg)",
  },
  selectPositioner: {
    zIndex: 20,
    outline: "none",
  },
  selectPopup: {
    minWidth: 210,
    maxHeight: "min(360px, var(--available-height))",
    padding: 5,
    borderWidth: 1,
    borderStyle: "solid",
    borderColor: landingColors.border,
    borderRadius: 12,
    backgroundColor: landingColors.elevated,
    color: landingColors.text,
    boxShadow: landingColors.popupShadow,
    overflowY: "auto",
    overscrollBehavior: "contain",
    outline: "none",
    transformOrigin: "var(--transform-origin)",
    transitionProperty: "opacity, transform",
    transitionDuration: "140ms",
    transitionTimingFunction: "cubic-bezier(0.2, 0, 0, 1)",
  },
  popupStarting: {
    opacity: 0,
    transform: "scale(0.97) translateY(3px)",
  },
  popupEnding: {
    opacity: 0,
    transform: "scale(0.98) translateY(2px)",
  },
  selectList: {
    display: "flex",
    flexDirection: "column",
    gap: 1,
    outline: "none",
  },
  selectItem: {
    minHeight: 34,
    paddingInline: 8,
    borderRadius: 8,
    display: "grid",
    gridTemplateColumns: "18px minmax(0, 1fr)",
    alignItems: "center",
    gap: 7,
    color: landingColors.secondaryText,
    cursor: "default",
    fontSize: 13,
    lineHeight: 1.2,
    outline: "none",
    userSelect: "none",
  },
  highlightedItem: {
    backgroundColor: landingColors.itemHighlight,
    color: landingColors.text,
  },
  selectedItem: {
    color: landingColors.text,
    fontWeight: 550,
  },
  itemIndicator: {
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    color: landingColors.text,
  },
  indicatorSlot: {
    width: 18,
    height: 18,
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
  },
  itemText: {
    display: "block",
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    textAlign: "start",
  },
  themePicker: {
    height: 38,
    padding: 3,
    borderRadius: 10,
    backgroundColor: landingColors.control,
    display: "grid",
    gridTemplateColumns: "repeat(3, 34px)",
    gap: 1,
  },
  themeOption: {
    width: 34,
    height: 32,
    borderRadius: 7,
    color: landingColors.secondaryText,
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    cursor: "pointer",
    outline: "none",
    transitionProperty: "background-color, color, box-shadow",
    transitionDuration: "140ms",
    ":hover": {
      color: landingColors.text,
    },
    ":focus-visible": {
      outlineWidth: 2,
      outlineStyle: "solid",
      outlineColor: landingColors.focus,
      outlineOffset: 2,
    },
  },
  selectedThemeOption: {
    backgroundColor: landingColors.selectedControl,
    color: landingColors.selectedText,
    boxShadow: "0 1px 2px rgba(0, 0, 0, 0.1), 0 0 0 1px rgba(0, 0, 0, 0.04)",
  },
  icon: {
    width: 18,
    height: 18,
    flexShrink: 0,
    fill: "none",
    stroke: "currentColor",
    strokeWidth: 1.35,
    strokeLinecap: "round",
    strokeLinejoin: "round",
  },
  smallIcon: {
    width: 16,
    height: 16,
    fill: "none",
    stroke: "currentColor",
    strokeWidth: 1.5,
    strokeLinecap: "round",
    strokeLinejoin: "round",
  },
  themeIcon: {
    width: 17,
    height: 17,
    fill: "none",
    stroke: "currentColor",
    strokeWidth: 1.35,
    strokeLinecap: "round",
    strokeLinejoin: "round",
  },
  englishInterfaceFont: {
    fontFamily: "'Red Hat Display', ui-sans-serif, system-ui, sans-serif",
  },
  persianFont: {
    fontFamily: "Vazirmatn, ui-sans-serif, system-ui, sans-serif",
  },
  nativeFont: {
    fontFamily:
      "ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif",
  },
})
