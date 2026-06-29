import type { ReactNode } from "react"
import { StyleSheet, Text, View } from "react-native"

import { colors } from "@/theme/colors"

type SectionProps = {
  title: string
  children: ReactNode
}

export function Section({ title, children }: SectionProps) {
  return (
    <View style={styles.wrap}>
      <Text style={styles.title}>{title}</Text>
      <View style={styles.body}>{children}</View>
    </View>
  )
}

export function Row({ label, value, children }: { label: string; value?: string; children?: ReactNode }) {
  return (
    <View style={styles.row}>
      <View style={styles.rowText}>
        <Text style={styles.label}>{label}</Text>
        {value ? <Text style={styles.value}>{value}</Text> : null}
      </View>
      {children}
    </View>
  )
}

const styles = StyleSheet.create({
  wrap: {
    gap: 8,
  },
  title: {
    color: colors.mutedText,
    fontSize: 13,
    fontWeight: "700",
    letterSpacing: 0,
    textTransform: "uppercase",
  },
  body: {
    overflow: "hidden",
    borderRadius: 8,
    backgroundColor: colors.surface,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
  },
  row: {
    minHeight: 56,
    paddingHorizontal: 16,
    paddingVertical: 10,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.border,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    gap: 12,
  },
  rowText: {
    flex: 1,
    gap: 3,
  },
  label: {
    color: colors.text,
    fontSize: 16,
    fontWeight: "500",
  },
  value: {
    color: colors.secondaryText,
    fontSize: 13,
  },
})
