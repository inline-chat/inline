import { app, BrowserWindow } from "electron";

app.whenReady().then(() => {
  const mainWindow = new BrowserWindow({
    width: 800,
    height: 600,
    //transparent: true,
    trafficLightPosition: {
      x: 30,
      y: 30,
    },
    frame: true,

    visualEffectState: "followWindow",
    titleBarOverlay: true,
    titleBarStyle: "hiddenInset",
    vibrancy: "popover",
  });
  mainWindow.loadURL("http://localhost:8001");
});
