import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { createHashRouter, RouterProvider } from "react-router-dom";
import { Shell } from "./components/Shell";
import { Overview } from "./pages/Overview";
import { TryIt } from "./pages/TryIt";
import { Attack } from "./pages/Attack";
import { How } from "./pages/How";
import { Verify } from "./pages/Verify";
import "./styles.css";

// Hash routing: the demo has to survive being opened from a static host, a file:// path, or a
// judge's bookmark without any server-side rewrite rules. A missing rewrite turning /verify into a
// 404 is exactly the kind of avoidable failure that costs a submission.
const router = createHashRouter([
  {
    path: "/",
    element: <Shell />,
    children: [
      { index: true, element: <Overview /> },
      { path: "try", element: <TryIt /> },
      { path: "attack", element: <Attack /> },
      { path: "how", element: <How /> },
      { path: "verify", element: <Verify /> },
    ],
  },
]);

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <RouterProvider router={router} />
  </StrictMode>
);
