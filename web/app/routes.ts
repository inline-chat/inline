import { type RouteConfig, index, route } from "@react-router/dev/routes"

export default [
  // / - landing page or app root
  index("./routes/home.tsx", { id: "landing-home" }),

  // website public pages
  route("privacy", "./routes/privacy.tsx"),
  route("feedback", "./routes/feedback.tsx"),
  route("docs", "./routes/docs.tsx"),

  // /home - alternative for loading landing page for authenticated users
  route("home", "./routes/home.tsx"),
] satisfies RouteConfig
