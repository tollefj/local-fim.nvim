class Cart:
    def __init__(self) -> None:
        self.items: list[str] = []

    def add(self, item: str) -> None:
        self.items.append(item)

    def checkout(self) -> None:
        total = <FIM>
        print(f"charged {total}")
