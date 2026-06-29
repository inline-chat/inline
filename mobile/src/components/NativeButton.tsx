import { Pressable, StyleSheet, Text, type PressableProps, type TextStyle, type ViewStyle } from "react-native"

import { colors } from "@/theme/colors"

type NativeButtonProps = PressableProps & {
  title: string
  tone?: "primary" | "secondary" | "danger"
  style?: ViewStyle
  textStyle?: TextStyle
}

export function NativeButton({ title, tone = "primary", style, textStyle, disabled, ...props }: NativeButtonProps) {
  return (
    <Pressable
      accessibilityRole="button"
      disabled={disabled}
      style={({ pressed }) => [
        styles.button,
        tone === "secondary" && styles.secondary,
        tone === "danger" && styles.danger,
        pressed && !disabled && styles.pressed,
        disabled && styles.disabled,
        style,
      ]}
      {...props}
    >
      <Text style={[styles.text, tone === "secondary" && styles.secondaryText, textStyle]}>{title}</Text>
    </Pressable>
  )
}

const styles = StyleSheet.create({
  button: {
    minHeight: 48,
    borderRadius: 8,
    alignItems: "center",
    justifyContent: "center",
    paddingHorizontal: 16,
    backgroundColor: colors.accent,
  },
  secondary: {
    backgroundColor: colors.surfaceMuted,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
  },
  danger: {
    backgroundColor: colors.danger,
  },
  pressed: {
    opacity: 0.82,
  },
  disabled: {
    opacity: 0.52,
  },
  text: {
    color: "white",
    fontSize: 16,
    fontWeight: "600",
  },
  secondaryText: {
    color: colors.text,
  },
})
