export const Spacer = ({ h, w }: { h?: number; w?: number }) => {
  return <div style={{ height: h ? `${h}px` : undefined, width: w ? `${w}px` : undefined }} />
}
