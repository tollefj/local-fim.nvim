def line_total(item: dict) -> float:
    return item["price"] * item["qty"] * (1 - item["discount"])
