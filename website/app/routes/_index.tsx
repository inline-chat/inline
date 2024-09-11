import type { MetaFunction } from "@remix-run/node"
import * as stylex from "@stylexjs/stylex"
import { useEffect, useState } from "react"

import "../landing.css"

export const meta: MetaFunction = () => {
  return [
    { title: "Inline – Messaging for high-performance teams" },
    {
      name: "description",
      content: "Team messaging that isn't from the 2010s",
    },
  ]
}

const centerWidth = 983
const centerHeight = 735
const firstContentRowHeight = 445

export default function Index() {
  const [mousePosition, setMousePosition] = useState({ x: 0, y: 0 })

  useEffect(() => {
    const handleMouseMove = (event: MouseEvent) => {
      setMousePosition({ x: event.clientX, y: event.clientY })
    }

    window.addEventListener("mousemove", handleMouseMove)

    return () => {
      window.removeEventListener("mousemove", handleMouseMove)
    }
  }, [])

  const calculateParallax = () => {
    if (typeof document === "undefined") return { x: 0, y: 0 }
    const centerElement = document.querySelector("#center")
    if (!centerElement) return { x: 0, y: 0 }

    const rect = centerElement.getBoundingClientRect()
    const centerX = rect.left + rect.width / 2
    const centerY = rect.top + rect.height / 2

    const offsetX = (mousePosition.x - centerX) / 50
    const offsetY = (mousePosition.y - centerY) / 50

    return { x: -offsetX, y: -offsetY }
  }

  const parallaxOffset = calculateParallax()

  return (
    <div className="font-sans p-4" {...stylex.props(styles.root)}>
      <div {...stylex.props(styles.centerBox, styles.center)} id="center">
        <div
          {...stylex.props(styles.centerBox, styles.bg)}
          style={{
            position: "absolute",
            transform: `translate(${parallaxOffset.x * 0.2}px, ${
              parallaxOffset.y * 0.15
            }px)`,
            boxShadow: `${parallaxOffset.x * 1.8}px ${
              20 + parallaxOffset.y * 1
            }px 20px -10px rgba(0, 0, 0, 0.2), inset
              0px -10px 30px 0px rgba(255, 255, 255, 0.2)`,
          }}
        />
        <div
          style={{
            position: "absolute",
            zIndex: 2,
            top: 0,
            left: 0,
            right: 0,
            bottom: 0,
            background: `linear-gradient(${55 + parallaxOffset.x * 1.5}deg, 
              rgba(255,255,255,0) 30%, 
              rgba(255,255,255,0.1) 40%, 
              rgba(255,255,255,0.8) 50%, 
              rgba(255,255,255,0.1) 60%, 
              rgba(255,255,255,0) 70%)`,
            opacity: 0.18,
            transform: `scale(1.5) translateX(${parallaxOffset.x * 2}px)`,
            pointerEvents: "none",
          }}
        />

        <div
          {...stylex.props(styles.content)}
          // style={{
          //   transform: `translate(${parallaxOffset.x * 0.1}px, ${
          //     parallaxOffset.y * 0.1
          //   }px)`,
          // }}
        >
          <h1 {...stylex.props(styles.logotype)}>
            <img
              src="/logotype-white.svg"
              alt="Inline"
              height="22px"
              width="96px"
            />
          </h1>
          <h2 {...stylex.props(styles.subheading)}>
            Team messaging <span {...stylex.props(styles.softBreak)} />
            that isn’t from{" "}
            <span
              {...stylex.props(styles.dated)}
              onPointerEnter={(e) => {
                const audio = new Audio("/sounds/slack-notification.mp3")
                audio.volume = 0.4
                audio.play()
              }}
            >
              2010s
            </span>
          </h2>
          <p {...stylex.props(styles.description)}>
            We’re building a native, high-quality chat app for teams who crave
            the best tools.
          </p>
          <a
            href="https://x.com/inline_chat"
            target="_blank"
            rel="noreferrer"
            {...stylex.props(styles.button)}
            style={{
              transform: `translate(${parallaxOffset.x * 0.2 * -1}px, ${
                parallaxOffset.y * 0.1 * -1
              }px)`,
            }}
          >
            <span
              style={{
                display: "block",
                transform: `translate(${parallaxOffset.x * 0.08 * -1}px, 0px)`,
              }}
            >
              Follow updates on X
            </span>
          </a>
        </div>

        <div {...stylex.props(styles.features)}>
          {[
            {
              title: "Lightweight",
              desc: "Sub-1% CPU usage, ultra-low RAM, and under-designed UI.",
            },
            {
              title: "Designed for speed",
              desc: "120-fps, instant app startup, no spinners. Works fast on any network.",
            },
            {
              title: "Simple",
              desc: "Powerful, intuitive and easy to use. Minimum clicks and modals, no clutter.",
            },
            {
              title: "Intelligent",
              desc: "Agents can process & insert data across apps triggered through custom reactions.",
            },
            {
              title: "Tranquil",
              desc: "Only what's relevant to you shows in the sidebar. Dig deeper at your will.",
            },
            {
              title: "Context-aware notifications",
              desc: "Stay in the zone as Inline differentiates urgent requests vs casual pings.",
            },
          ].map(({ title, desc }) => (
            <div {...stylex.props(styles.card)} key={title}>
              <h3 {...stylex.props(styles.cardHeading)}>{title}</h3>
              <p {...stylex.props(styles.cardText)}>{desc}</p>
            </div>
          ))}
        </div>
      </div>

      {/* == */}
      <div {...stylex.props(styles.footer)}>
        <div>
          <div>
            Early access starting in October 2024 for macOS and iOS • Written in
            Swift.
          </div>
        </div>

        <div {...stylex.props(styles.footerSecondRow)}>
          <a
            href="mailto:hey@inline.chat"
            target="_blank"
            rel="noopener noreferrer"
            {...stylex.props(styles.footerLink)}
          >
            hey@inline.chat
          </a>
          <div>
            <a
              href="https://x.com/inline_chat"
              target="_blank"
              rel="noopener noreferrer"
              {...stylex.props(styles.footerLink)}
            >
              X (Twitter)
            </a>
          </div>
          <div>
            <a
              href="https://noor.to"
              target="_blank"
              rel="noopener noreferrer"
              {...stylex.props(styles.footerLink)}
            >
              Our previous app
            </a>
          </div>
        </div>

        <div {...stylex.props(styles.footerSecondRow)}>
          <div {...stylex.props(styles.copyRight)}>© 2024 Inline Chat</div>
        </div>
      </div>
    </div>
  )
}

let flash = stylex.keyframes({
  "0%": { opacity: 1 },
  "50%": { opacity: 0.5 },
  "100%": { opacity: 1 },
})

const styles = stylex.create({
  root: {
    // default text style
    fontSize: 15,
    minHeight: "100%",

    fontWeight: "400",
    fontFamily: '"RM Neue", sans-serif',
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    justifyContent: {
      default: "center",
      "@media (max-width: 1000px)": "flex-start",
    },
    padding: {
      default: "0",
      "@media (max-width: 1000px)": 12,
    },
    paddingTop: {
      default: 32,
      "@media (max-width: 1000px)": 12,
    },
    overflow: "hidden",
  },

  centerBox: {
    width: {
      default: centerWidth,
      "@media (max-width: 1000px)": "100%",
    },
    height: {
      default: centerHeight,
      "@media (max-width: 1000px)": "100%",
    },
    borderRadius: {
      default: 12,
      "@media (max-width: 1000px)": 10,
    },
  },

  bg: {
    top: 0,
    left: 0,
    backgroundImage: `url(/content-bg.jpg), linear-gradient(
   to bottom,
    #536D9C 0%,
    #5476A3 40%,
    #7D9AAA 60%,
    #5A6A7B 80%,
    #303848 100%

  )`,
    "@media (-webkit-min-device-pixel-ratio: 2), (min-resolution: 192dpi)": {
      backgroundImage: "url(/content-bg@2x.jpg)",
    },
    backgroundSize: "cover",
    backgroundPosition: "center",
    zIndex: 1,
    overflow: "hidden",

    "::after": {
      content: '""',
      display: {
        default: "none",
        "@media (max-width: 1000px)": "block",
      },
      position: "absolute",
      top: 0,
      left: 0,
      right: 0,
      bottom: 0,
      backdropFilter: "blur(30px)",
      WebkitBackdropFilter: "blur(30px)", // For Safari support
      // zIndex: 2,
    },
  },

  center: {
    display: "block",
    margin: "0 auto",
    position: "relative",
    color: "white",
  },

  content: {
    paddingLeft: 32,
    paddingRight: 32,
    paddingTop: 16,

    position: "relative",
    zIndex: 3,
    height: firstContentRowHeight,
    textAlign: "center",
    display: "flex",
    flexDirection: "column",
    justifyContent: "center",
    alignItems: "center",
  },

  features: {
    position: "relative",
    zIndex: 3,
    display: "grid",
    gridTemplateColumns: {
      default: "repeat(3, 1fr)",
      "@media (min-width: 800px) and (max-width: 1000px)": "repeat(2, 1fr)",
      "@media (max-width: 800px)": "repeat(1, 1fr)",
    },
    gridTemplateRows: {
      default: "repeat(2, auto)",
      "@media (min-width: 800px) and (max-width: 1000px)": "repeat(3, auto)",
      "@media (max-width: 800px)": "repeat(6, auto)",
    },

    rowGap: 32,
    columnGap: 28,
    padding: "50px 50px",
  },

  card: {},

  cardHeading: {
    fontFamily: '"Red Hat Display", sans-serif',
    fontWeight: "700",
    fontSize: 15,
    marginBottom: 4,
    color: "rgba(255,255,255,0.95)",
    textShadow: "0 1px 1px rgba(0,0,0,0.1)",
  },
  cardText: {
    fontSize: 15,
    color: "rgba(255,255,255,0.85)",
    textShadow: "0 1px 1px rgba(0,0,0,0.1)",
  },

  logotype: {
    marginBottom: 32,
    opacity: {
      default: 0.94,
      ":hover": 1,
    },
    filter: {
      default: "drop-shadow(0 1px 1px rgba(0,0,0,0.1))",
      ":hover": "drop-shadow(0 3px 10px rgba(255,255,255,0.4))",
    },
    transition: "opacity 0.15s ease-out, filter 0.15s ease-out",
  },

  subheading: {
    marginBottom: 18,
    fontSize: { default: 48, "@media (max-width: 500px)": 28 },
    lineHeight: 1.2,
    fontWeight: "700",
    maxWidth: 480,
    fontFamily: '"Red Hat Display", sans-serif',
    WebkitFontSmoothing: "unset",
    MozOsxFontSmoothing: "unset",
    textShadow: "0 1px 1px rgba(0,0,0,0.1)",
  },

  softBreak: {
    display: "block",
    "@media (max-width: 500px)": {
      display: "none",
    },
  },

  description: {
    fontSize: { default: 18, "@media (max-width: 500px)": 15 },
    maxWidth: 425,
    marginBottom: 28,
    color: "rgba(255,255,255,0.88)",
    textShadow: "0 1px 1px rgba(0,0,0,0.1)",
  },

  button: {
    display: "inline-block",
    minWidth: 230,
    height: 40,
    lineHeight: "40px",
    userSelect: "none",
    backgroundColor: {
      default: "rgba(255,255,255,0.24)",
      ":hover": "rgba(255,255,255,0.32)",
      ":active": "rgba(255,255,255,0.35)",
    },
    boxShadow: {
      default:
        "inset 0 1px 0 0 rgba(255, 255, 255, 0.2), 0 -1px 2px 2px rgba(255, 255, 255, 0.05)",
      ":hover":
        "inset 0 1px 0 0 rgba(255, 255, 255, 0.5), 0 -1px 2px 2px rgba(255, 255, 255, 0.1), 0 -3px 6px 5px rgba(255, 255, 255, 0.06)",
    },
    textShadow: "0 1px 1px rgba(0,0,0,0.1)",
    transform: {
      default: "scale(1)",
      ":active": "scale(0.95)",
    },
    backdropFilter: "blur(25px)",
    color: "white",
    borderRadius: 25,
    textDecoration: "none",
    fontSize: { default: 18, "@media (max-width: 500px)": 15 },
    fontWeight: "700",
    transition:
      "background-color 0.15s ease-out, transform 0.18s ease-out, box-shadow 0.15s ease-out",
  },

  footer: {
    textAlign: "center",
    width: {
      default: centerWidth,
      "@media (max-width: 1000px)": "100%",
    },
    padding: "44px 50px",
    fontFamily: '"Reddit Mono", monospace',
    fontSize: 13,
    color: "rgba(44, 54, 66, 0.8)",
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    justifyContent: "center",
  },

  footerSecondRow: {
    display: "flex",
    flexDirection: {
      default: "row",
      "@media (max-width: 500px)": "column",
    },
    textAlign: {
      default: "unset",
      "@media (max-width: 500px)": "center",
    },
    marginTop: 8,
  },

  copyRight: {
    marginRight: "auto",
    color: "rgba(44, 54, 66, 0.4)",
  },

  footerLink: {
    position: "relative",
    color: {
      default: "rgba(44, 54, 66, 0.6)",
      ":hover": "rgba(44, 54, 66, 0.8)",
    },
    marginLeft: {
      default: 24,
      "@media (max-width: 500px)": 0,
    },
  },

  dated: {
    cursor: "wait",
    opacity: 1,
    animationDuration: "0.12s",
    animationIterationCount: 4,
    animationTimingFunction: "ease-in",
    animationName: {
      default: "none",
      ":hover": flash,
    },
    animationPlayState: {
      default: "paused",
      ":hover": "running",
    },
  },
})
