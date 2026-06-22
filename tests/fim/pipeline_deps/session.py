from pipeline_deps.response import Response


class Session:
    def __init__(self, app, user: str) -> None:
        self.app = app
        self.user = user

    def exchange(self, message: str) -> Response:
        return Response(f"{self.user}: {message}")

    def close(self) -> None:
        self.app = None
