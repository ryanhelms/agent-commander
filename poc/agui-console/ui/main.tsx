// Bundle entry. Output is served as /ui.js and /ui.css.
import React from "react";
import { createRoot } from "react-dom/client";
import { CopilotKitProvider } from "@copilotkit/react-core/v2";

import "./foundations/tokens.css";
import "./foundations/components.css";

import { ConsolePage, ConsoleErrorBoundary } from "./pages";

const root = document.getElementById("root");
if (!root) throw new Error("Missing #root element");

createRoot(root).render(
  <React.StrictMode>
    <ConsoleErrorBoundary>
      <CopilotKitProvider runtimeUrl="/api/copilotkit">
        <ConsolePage />
      </CopilotKitProvider>
    </ConsoleErrorBoundary>
  </React.StrictMode>,
);
