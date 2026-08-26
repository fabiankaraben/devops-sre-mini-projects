"""Playwright Multi-Step Synthetic User Journey Runner with Automated Failure Screenshots."""

import asyncio
import os
import time
from typing import Dict, List, Optional
from playwright.async_api import async_playwright, Browser, BrowserContext, Page, TimeoutError as PlaywrightTimeoutError

BASE_URL = os.getenv("TARGET_APP_URL", "http://target-app:8080")
SCREENSHOTS_DIR = os.getenv("SCREENSHOTS_DIR", "/app/screenshots")


class JourneyStepException(Exception):
    def __init__(self, step: str, message: str, screenshot_path: Optional[str] = None):
        super().__init__(f"Step '{step}' failed: {message}")
        self.step = step
        self.message = message
        self.screenshot_path = screenshot_path


class SyntheticCheckoutJourney:
    """Simulates a real end-to-end e-commerce customer purchase workflow using Playwright."""

    def __init__(self, base_url: str = BASE_URL, screenshots_dir: str = SCREENSHOTS_DIR):
        self.base_url = base_url.rstrip("/")
        self.screenshots_dir = screenshots_dir
        os.makedirs(self.screenshots_dir, exist_ok=True)

    async def execute(self) -> Dict:
        """Executes all steps sequentially and records step durations and status."""
        journey_start = time.perf_counter()
        step_timings = {}
        journey_result = {
            "journey": "checkout_flow",
            "success": False,
            "total_duration_seconds": 0.0,
            "steps": {},
            "failed_step": None,
            "error": None,
            "screenshot": None,
            "timestamp": time.time(),
        }

        async with async_playwright() as p:
            browser: Browser = await p.chromium.launch(
                headless=True,
                args=[
                    "--no-sandbox",
                    "--disable-setuid-sandbox",
                    "--disable-dev-shm-usage",
                    "--disable-gpu",
                ],
            )
            context: BrowserContext = await browser.new_context(
                viewport={"width": 1280, "height": 720},
                user_agent="SyntheticMonitorBot/1.0 (SRE-Health-Probe; Playwright)",
            )
            page: Page = await context.new_page()
            # Set default timeout to 8 seconds
            page.set_default_timeout(8000)

            current_step = "unknown"
            try:
                # --------------------------------------------------------------
                # Step 1: Navigate to Homepage / Catalog
                # --------------------------------------------------------------
                current_step = "navigate_home"
                t0 = time.perf_counter()
                await page.goto(f"{self.base_url}/", wait_until="networkidle")
                await page.wait_for_selector("#product-grid", state="visible")
                step_timings["navigate_home"] = time.perf_counter() - t0

                # --------------------------------------------------------------
                # Step 2: User Authentication
                # --------------------------------------------------------------
                current_step = "user_login"
                t0 = time.perf_counter()
                await page.goto(f"{self.base_url}/login", wait_until="networkidle")
                await page.fill("#email", "sre-synthetic@cloudstore.io")
                await page.fill("#password", "SyntheticPass2026!")
                await page.click("#btn-submit-login")
                await page.wait_for_selector("#cart-count", state="visible")
                step_timings["user_login"] = time.perf_counter() - t0

                # --------------------------------------------------------------
                # Step 3: Browse Catalog & Add Item to Cart
                # --------------------------------------------------------------
                current_step = "add_to_cart"
                t0 = time.perf_counter()
                await page.goto(f"{self.base_url}/", wait_until="networkidle")
                await page.wait_for_selector("#btn-add-prod-101", state="visible")
                await page.click("#btn-add-prod-101")
                # Wait for navigation to cart page
                await page.wait_for_selector("#cart-table", state="visible")
                step_timings["add_to_cart"] = time.perf_counter() - t0

                # --------------------------------------------------------------
                # Step 4: Proceed to Checkout Page
                # --------------------------------------------------------------
                current_step = "proceed_to_checkout"
                t0 = time.perf_counter()
                await page.wait_for_selector("#btn-proceed-checkout", state="visible")
                await page.click("#btn-proceed-checkout")
                await page.wait_for_selector("#checkout-form-card", state="visible")
                step_timings["proceed_to_checkout"] = time.perf_counter() - t0

                # --------------------------------------------------------------
                # Step 5: Fill Shipping/Payment & Submit Order
                # --------------------------------------------------------------
                current_step = "submit_order"
                t0 = time.perf_counter()
                await page.fill("#full_name", "Alex SRE")
                await page.fill("#address", "777 Reliability Blvd, Zone A")
                await page.fill("#card_number", "4242 4242 4242 4242")
                await page.fill("#exp_date", "11/29")
                await page.fill("#cvv", "999")
                await page.click("#btn-place-order")

                # Verify confirmation page and order reference badge
                await page.wait_for_selector("#order-confirmed-heading", state="visible")
                await page.wait_for_selector("#order-id-badge", state="visible")
                step_timings["submit_order"] = time.perf_counter() - t0

                # Mark entire journey as success
                journey_result["success"] = True
                journey_result["steps"] = step_timings
                journey_result["total_duration_seconds"] = time.perf_counter() - journey_start

            except Exception as exc:
                journey_result["success"] = False
                journey_result["failed_step"] = current_step
                journey_result["error"] = str(exc)
                journey_result["steps"] = step_timings
                journey_result["total_duration_seconds"] = time.perf_counter() - journey_start

                # Capture diagnostic screenshot on failure
                timestamp_str = time.strftime("%Y%m%d_%H%M%S")
                screenshot_filename = f"failure_{timestamp_str}_{current_step}.png"
                screenshot_path = os.path.join(self.screenshots_dir, screenshot_filename)
                try:
                    await page.screenshot(path=screenshot_path, full_page=True)
                    journey_result["screenshot"] = screenshot_filename
                except Exception as screen_exc:
                    journey_result["screenshot_error"] = str(screen_exc)

            finally:
                await context.close()
                await browser.close()

        return journey_result
