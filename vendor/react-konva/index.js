"use client";
const React = require("react");
const pass = (tag) => React.forwardRef(function Node(props, ref) {
  const { children, ...rest } = props;
  const mapped = { ...rest };
  if (mapped.strokeWidth != null) mapped["stroke-width"] = mapped.strokeWidth;
  if (mapped.fontSize != null) mapped["font-size"] = mapped.fontSize;
  if (mapped.cornerRadius != null) { mapped.rx = mapped.cornerRadius; mapped.ry = mapped.cornerRadius; }
  delete mapped.strokeWidth; delete mapped.fontSize; delete mapped.cornerRadius;
  return React.createElement(tag, { ...mapped, ref }, children);
});
exports.Stage = React.forwardRef(function Stage({ width, height, x=0, y=0, scaleX=1, scaleY=1, children, ...props }, ref) {
  return React.createElement("div", { ...props, ref, style: { touchAction:"none", ...props.style } }, React.createElement("svg", { width:"100%", height:"100%", viewBox:`0 0 ${width} ${height}`, xmlns:"http://www.w3.org/2000/svg" }, React.createElement("g", { transform:`translate(${x} ${y}) scale(${scaleX} ${scaleY})` }, children)));
});
exports.Layer = pass("g"); exports.Group = pass("g"); exports.Rect = pass("rect"); exports.Circle = pass("circle"); exports.Line = React.forwardRef(function Line({points=[], ...props},ref){ return React.createElement("polyline", {...props, ref, points:points.join(" "), fill:props.closed ? props.fill : "none"});}); exports.Text = pass("text"); exports.Transformer = () => null;
