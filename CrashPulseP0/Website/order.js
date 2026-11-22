async function checkPayment() {
  try {
    const response = await fetch(window.location.pathname + "/status", { cache: "no-store" });
    if (response.ok && (await response.json()).paid === true) {
      window.location.reload();
      return;
    }
  } catch {
    // Retry after a transient network interruption.
  }
  window.setTimeout(checkPayment, 3000);
}

checkPayment();
