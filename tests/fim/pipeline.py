from pipeline_deps.app import build_app


def main() -> None:
    app = build_app()
    session = app.create_session("alice")
    reply = session.<FIM>
    print(reply.text)
