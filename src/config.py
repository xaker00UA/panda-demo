from pydantic_settings import BaseSettings, SettingsConfigDict


class Config(BaseSettings):
    GIT_TAG: str | None = None
    GIT_SHORT_HASH: str
    DATABASE_URL: str

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")


config = Config() # type: ignore
