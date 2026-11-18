/**
 * The kit's controllers for the message action layers: the reaction picker
 * (a popover anchored at the Add Reaction button or the row) and the
 * confirmation alert. In the layers chunk (`src/app/layers-chunk.ts`), so the
 * kit's popover and dialog code is not in the initial bundle.
 */

import { DialogController, PopoverController } from "@inline/ui"
import type { MessageLayersFactory } from "./message-actions"

export const kitLayers: MessageLayersFactory = (callbacks) => ({
  picker: new PopoverController({
    placement: "top-start",
    offset: 6,
    role: "dialog",
    label: "Add reaction",
    anchor: callbacks.anchor,
    onOpenChange: (open) => {
      if (!open) callbacks.pickerClosed()
    },
  }),
  confirm: new DialogController({
    role: "alertdialog",
    label: "Confirm",
    onOpenChange: (open) => {
      if (!open) callbacks.confirmClosed()
    },
  }),
})
