import { app, BrowserWindow, nativeImage, NativeImage } from "electron";
import { isMacOS } from "./utils";

app.whenReady().then(() => {
  // Set dev icon
  if (isMacOS) {
    let image = nativeImage.createFromPath("./assets/dev-app-icon-256.png");
    app.dock?.setIcon(image);
  }

  const mainWindow = new BrowserWindow({
    width: 800,
    height: 600,
    transparent: true,
    trafficLightPosition: {
      x: 16,
      y: 16,
    },

    frame: true,

    visualEffectState: "followWindow",
    titleBarOverlay: true,
    titleBarStyle: "hidden",
    vibrancy: "popover",
  });

  mainWindow.loadURL("http://localhost:8001/app");
});
