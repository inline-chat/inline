import type { MetaFunction } from "@remix-run/node"
import * as stylex from "@stylexjs/stylex"
import { useEffect, useRef, useState } from "react"
import { AnimatePresence, motion } from "framer-motion"

import "../landing.css"

export const meta: MetaFunction = () => {
  return [
    { title: "Inline – Messaging for teams that want the best tools" },
    {
      name: "description",
      content: "Team messaging that's not from the 2010s",
    },
  ]
}

const messagesLength = 4
const apiEndpoint =
  process.env.NODE_ENV == "production"
    ? "https://headline.inline.chat"
    : "http://localhost:8000"
const centerWidth = 983
const centerHeight = 735
const cardRadius = 22
const firstContentRowHeight = 445
const buttonHeight = 44
export default function Index() {
  const [focused, setFocused] = useState(false)
  const [email, setEmail] = useState("")
  const [submitting, setSubmitting] = useState(false)
  const [failed, setFailed] = useState(false)
  const [subscribed, setSubscribed] = useState(false)
  const [isntInitialRender, setIsntInitialRender] = useState(false)

  const [formActive, setFormActive] = useState(false)
  const inputRef = useRef<HTMLInputElement>(null)

  useEffect(() => {
    setIsntInitialRender(true)
  }, [])

  const lastPlayedAtRef = useRef(0)
  const [message, setMessage] = useState(0)
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
      <motion.div
        {...stylex.props(styles.centerBox, styles.center)}
        id="center"
        animate={{}}
      >
        <motion.div
          {...stylex.props(styles.centerBox, styles.bg)}
          animate={{
            filter: formActive
              ? "blur(4px) brightness(1.2)"
              : "blur(0px) brightness(1.1)",
          }}
          style={{
            position: "absolute",
            transform: `translate(${parallaxOffset.x * 0.2}px, ${
              parallaxOffset.y * 0.15
            }px)`,

            boxShadow: `${parallaxOffset.x * 1.8}px ${
              20 + parallaxOffset.y * 1
            }px 20px -10px rgba(0, 0, 0, 0.2)`,
          }}
        >
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
              rgba(255,255,255,0.9) 50%, 
              rgba(255,255,255,0.1) 60%, 
              rgba(255,255,255,0) 70%)`,
              opacity: 0.18,
              transform: `scale(1.5) translateX(${
                parallaxOffset.x * -2
              }px) translateY(${parallaxOffset.y * -1}px)`,
              pointerEvents: "none",
              boxShadow: "inset 0px 10px 80px 120px rgba(255, 255, 255, 1)",
            }}
          />
        </motion.div>

        <div
          {...stylex.props(styles.content)}
          // style={{
          //   transform: `translate(${parallaxOffset.x * 0.1}px, ${
          //     parallaxOffset.y * 0.1
          //   }px)`,
          // }}
        >
          <h1 {...stylex.props(styles.logotype)}>
            <motion.div>
              <motion.img
                drag
                whileTap={{ scale: 1.15 }}
                dragElastic={0.1}
                dragConstraints={{
                  top: 10,
                  left: 10,
                  right: 10,
                  bottom: 10,
                }}
                src="/logotype-white.svg"
                alt="Inline"
                height="22px"
                width="96px"
              />
            </motion.div>
          </h1>
          <motion.h2
            layout="preserve-aspect"
            {...stylex.props(styles.subheading)}
            onClick={() => {
              setMessage((m) => (m < messagesLength - 1 ? m + 1 : 0))
            }}
          >
            {message === 0 && (
              <>
                Chat that isn't from{" "}
                <span
                  {...stylex.props(styles.dated)}
                  onPointerEnter={(e) => {
                    // limit it to once per 2s
                    if (Date.now() - lastPlayedAtRef.current < 1500) return
                    const audio = new Audio("/sounds/slack-notification.mp3")
                    audio.volume = 0.2
                    audio.play()
                    lastPlayedAtRef.current = Date.now()
                  }}
                >
                  2010s
                </span>
              </>
            )}
            {message === 1 && <>Where chat happens</>}
            {message === 2 && <>iMessage, but powerful & for teams</>}
            {message === 3 && <>Messaging for focused work</>}
          </motion.h2>
          <p {...stylex.props(styles.description)}>
            We’re building a native, high-quality messaging app for teams who
            crave the best tools.
          </p>

          <div
            style={{
              height: buttonHeight,
              position: "relative",
              display: "flex",
              justifyContent: "center",
              alignItems: "center",
            }}
          >
            <AnimatePresence>
              {formActive ? (
                <motion.form
                  key="form"
                  initial={{ opacity: 0, width: 0, scale: 0.6 }}
                  animate={{
                    opacity: 1,
                    width: 300,
                    scale: 1,
                  }}
                  exit={{ opacity: 0, width: 0, scale: 0.6 }}
                  onSubmit={(e) => {
                    e.preventDefault()
                    setFormActive(false)
                    setSubmitting(true)

                    const revert = () => {
                      setTimeout(() => {
                        setFormActive(false)
                        setSubmitting(false)
                        setSubscribed(false)
                        setFailed(false)
                      }, 1500)
                    }

                    // submit
                    fetch(`${apiEndpoint}/waitlist/subscribe`, {
                      method: "POST",
                      headers: {
                        "Content-Type": "application/json",
                      },
                      body: JSON.stringify({
                        email,
                        userAgent: navigator.userAgent,
                        timeZone:
                          Intl.DateTimeFormat().resolvedOptions().timeZone,
                      }),
                    })
                      .then(() => {
                        setFormActive(false)
                        setSubmitting(false)
                        setSubscribed(true)
                        setEmail("")
                        revert()
                      })
                      .catch(() => {
                        setFailed(true)
                        setFormActive(false)
                        setSubmitting(false)
                        setSubscribed(false)
                        revert()
                      })
                  }}
                  {...stylex.props(
                    styles.emailForm,
                    focused ? styles.emailFormActive : null,
                  )}
                  style={{
                    top: 0,
                    overflow: "hidden",
                    position: "absolute",
                    transform: `translate(${parallaxOffset.x * 0.2 * -1}px, ${
                      parallaxOffset.y * 0.1 * -1
                    }px)`,
                  }}
                >
                  <motion.input
                    key="input"
                    type="email"
                    ref={inputRef}
                    placeholder="What's your work email?"
                    {...stylex.props(styles.emailInput)}
                    value={email}
                    onChange={(e) => setEmail(e.target.value)}
                    onFocus={() => {
                      setFocused(true)
                    }}
                    onBlur={() => {
                      setFocused(false)
                    }}
                    onKeyDown={(e) => {
                      if (e.key === "Escape") {
                        setFormActive(false)
                      }
                    }}
                  />

                  <motion.button {...stylex.props(styles.emailButton)}>
                    <svg
                      xmlns="http://www.w3.org/2000/svg"
                      width="24"
                      height="24"
                      viewBox="0 0 24 24"
                      fill="none"
                      stroke="currentColor"
                      strokeWidth="2"
                      strokeLinecap="round"
                      strokeLinejoin="round"
                    >
                      <line x1="5" y1="12" x2="19" y2="12"></line>
                      <polyline points="12 5 19 12 12 19"></polyline>
                    </svg>
                  </motion.button>
                </motion.form>
              ) : (
                <motion.div
                  key="btn"
                  {...stylex.props(styles.button)}
                  initial={
                    isntInitialRender
                      ? { opacity: 0, width: 0, scale: 0.6 }
                      : undefined
                  }
                  animate={{
                    opacity: 1,
                    width: 300,
                    scale: 1,
                  }}
                  exit={{ opacity: 0, scale: 0.6, width: 0 }}
                  style={{
                    top: 0,
                    position: "absolute",
                    transform: `translate(${parallaxOffset.x * 0.2 * -1}px, ${
                      parallaxOffset.y * 0.1 * -1
                    }px)`,
                  }}
                  onClick={(e) => {
                    e.preventDefault()
                    setFormActive(true)
                    requestAnimationFrame(() => {
                      // focus input
                      inputRef.current?.focus()
                      inputRef.current?.select()
                    })
                  }}
                  whileTap={{ scale: formActive ? 1 : 0.95 }}
                >
                  <span
                    style={{
                      display: "block",
                      transform: `translate(${
                        parallaxOffset.x * 0.08 * -1
                      }px, 0px)`,
                      whiteSpace: "nowrap",
                    }}
                  >
                    {failed
                      ? "Failed to submit"
                      : submitting
                      ? "Submitting..."
                      : subscribed
                      ? "You're on the waitlist 🎉"
                      : "Get on the Waitlist"}
                  </span>
                </motion.div>
              )}
            </AnimatePresence>
          </div>
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
              desc: "Agents can handle workflows across apps via custom reaction triggers.",
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
      </motion.div>

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
              Follow updates on X (Twitter)
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
      default: cardRadius,
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

    rowGap: 40,
    columnGap: 34,
    padding: "52px 60px",
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
    cursor: "default",
    // maxWidth: 480,
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
    fontSize: { default: 21, "@media (max-width: 500px)": 18 },
    maxWidth: 445,
    marginBottom: 28,
    cursor: "default",
    color: "rgba(255,255,255,0.88)",
    textShadow: "0 1px 1px rgba(0,0,0,0.1)",
  },

  button: {
    overflow: "hidden",
    height: buttonHeight,
    width: 300,
    textAlign: "center",
    userSelect: "none",
    cursor: "pointer",
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
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    flexDirection: "row",
    backdropFilter: "blur(25px)",
    color: "white",
    borderRadius: 40,
    textDecoration: "none",
    fontSize: { default: 18, "@media (max-width: 500px)": 15 },
    fontWeight: "700",
    transition:
      "background-color 0.15s ease-out, transform 0.18s ease-out, box-shadow 0.15s ease-out",
  },

  emailForm: {
    height: buttonHeight,
    paddingLeft: 4,
    paddingRight: 4,
    userSelect: "none",
    cursor: "pointer",
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
    display: "flex",
    alignItems: "center",
    flexDirection: "row",
    backdropFilter: "blur(25px)",
    color: "white",
    borderRadius: 40,
    textDecoration: "none",
    fontSize: { default: 18, "@media (max-width: 500px)": 15 },
    fontWeight: "700",
    transition:
      "background-color 0.15s ease-out, transform 0.18s ease-out, box-shadow 0.15s ease-out",
  },

  emailFormActive: {
    backgroundColor: "rgba(255,255,255,0.35)",
    boxShadow:
      "inset 0 1px 0 0 rgba(255, 255, 255, 0.5), 0 -1px 2px 2px rgba(255, 255, 255, 0.1), 0 -3px 6px 5px rgba(255, 255, 255, 0.06)",
  },

  emailInput: {
    height: buttonHeight - 8,
    background: "none",
    width: "100%",
    minWidth: 0,
    flexShrink: 1,
    color: "white",
    fontWeight: 700,
    textAlign: "center",
    fontSize: 18,
    "::placeholder": {
      color: "rgba(255,255,255,0.9)",
      fontWeight: 400,
    },
    border: "none",
    outline: "none",
  },

  emailButton: {
    flexShrink: 0,
    height: buttonHeight - 8,
    width: buttonHeight - 8,
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    fontSize: 18,
    background: {
      default: "rgba(255,255,255,0.2)",
      ":hover": "rgba(255,255,255,0.3)",
    },
    transition: "background-color 0.15s ease-out",
    borderRadius: 25,
  },

  footer: {
    textAlign: "center",
    width: {
      default: centerWidth,
      "@media (max-width: 1000px)": "100%",
    },
    color: {
      default: "rgba(44, 54, 66, 0.8)",
      "@media (prefers-color-scheme: dark)": "rgba(255,255,255,0.8)",
    },
    padding: "60px 50px",
    fontFamily: '"Reddit Mono", monospace',
    fontSize: 14,
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
    opacity: 0.5,
  },

  footerLink: {
    position: "relative",
    display: "block",
    padding: "4px 8px",
    opacity: {
      default: 0.8,
      ":hover": 1,
    },
    marginLeft: {
      default: 24,
      "@media (max-width: 500px)": 0,
    },
    transition: "color 0.12s ease-out",
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
