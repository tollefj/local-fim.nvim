class Response:
    def __init__(self, text: str) -> None:
        self.text = text

    def ok(self) -> bool:
        return bool(self.text)
