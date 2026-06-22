class Greeter:
    def __init__(self, name: str) -> None:
        self.name = name

    def greeting(self) -> str:
        return f"Hello, {self.name}!"

    def shout(self) -> str:
        return self.greeting().upper()
