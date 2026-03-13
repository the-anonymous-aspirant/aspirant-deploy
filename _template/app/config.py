import os


DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    "postgresql://{user}:{password}@{host}/{name}".format(
        user=os.environ.get("DB_USER", "postgres"),
        password=os.environ.get("DB_PASSWORD", "postgres"),
        host=os.environ.get("DB_HOST", "postgres"),
        name=os.environ.get("DB_NAME", "aspirant_online_db"),
    ),
)

# Service-specific configuration
# SERVICE_SETTING = os.environ.get("SERVICE_SETTING", "default_value")
