import { render, screen } from "@testing-library/react";
import { Badge, severityWeight } from "./Badge.js";

describe("severityWeight", () => {
  it("maps severities to weights", () => {
    expect(severityWeight("critical")).toBe(10);
    expect(severityWeight("low")).toBe(1);
  });
});

describe("Badge", () => {
  it("renders the label and its severity weight", () => {
    render(<Badge label="SQL injection" severity="high" />);
    const el = screen.getByTestId("badge");
    expect(el).toHaveTextContent("SQL injection (7)");
    expect(el).toHaveAttribute("data-severity", "high");
  });
});
