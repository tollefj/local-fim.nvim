from pipeline_deps.session import Session


class App:
    def __init__(self, name: str) -> None:
        self.name = name

    def create_session(self, user: str) -> Session:
        return Session(self, user)


def build_app() -> App:
    return App("demo")
