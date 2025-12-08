import { app, BrowserWindow } from "electron";

app.whenReady().then(() => {
  const mainWindow = new BrowserWindow({
    width: 800,
    height: 600,
    transparent: true,
    trafficLightPosition: {
      x: 14,
      y: 14,
    },

    frame: true,

    visualEffectState: "followWindow",
    titleBarOverlay: true,
    titleBarStyle: "hidden",
    vibrancy: "popover",
  });
  mainWindow.loadURL("http://localhost:8001/app");
});
