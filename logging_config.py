"""
Logging configuration module for ELK stack integration.
Provides structured logging with Logstash handler for centralized log management.
"""

import os
import logging
import logstash


class LoggerConfig:
    """
    Configures and manages application logging with ELK stack integration.

    Features:
    - Console logging for local development
    - Logstash handler for centralized logging
    - Structured logging with extra fields
    """

    def __init__(
        self,
        logger_name: str = "model_api",
        log_level: int = logging.INFO,
        logstash_host: str = None,
        logstash_port: int = None
    ):
        """
        Initialize logger configuration.

        Args:
            logger_name: Name of the logger
            log_level: Logging level (default: INFO)
            logstash_host: Logstash host (default: from env or 'logstash')
            logstash_port: Logstash port (default: from env or 5044)
        """
        self.logger_name = logger_name
        self.log_level = log_level
        self.logstash_host = logstash_host or os.getenv("LOGSTASH_HOST", "logstash")
        self.logstash_port = logstash_port or int(os.getenv("LOGSTASH_PORT", "5044"))

        self.logger = self._setup_logger()

    def _setup_logger(self) -> logging.Logger:
        """
        Set up and configure the logger with console and Logstash handlers.

        Returns:
            Configured logger instance
        """
        logger = logging.getLogger(self.logger_name)
        logger.setLevel(self.log_level)

        # Clear any existing handlers to avoid duplicates
        logger.handlers.clear()

        # Console handler for local development
        console_handler = logging.StreamHandler()
        console_handler.setLevel(self.log_level)
        console_formatter = logging.Formatter(
            '%(asctime)s - %(name)s - %(levelname)s - %(message)s'
        )
        console_handler.setFormatter(console_formatter)
        logger.addHandler(console_handler)

        # Logstash handler for ELK stack
        try:
            logstash_handler = logstash.TCPLogstashHandler(
                self.logstash_host,
                self.logstash_port,
                version=1
            )
            logger.addHandler(logstash_handler)
            logger.info(
                f"Logstash handler configured: {self.logstash_host}:{self.logstash_port}"
            )
        except Exception as e:
            logger.warning(
                f"Could not connect to Logstash at {self.logstash_host}:{self.logstash_port}: {e}"
            )

        return logger

    def get_logger(self) -> logging.Logger:
        """
        Get the configured logger instance.

        Returns:
            Logger instance
        """
        return self.logger


def setup_logger(
    logger_name: str = "model_api",
    log_level: int = logging.INFO,
    logstash_host: str = None,
    logstash_port: int = None
) -> logging.Logger:
    """
    Convenience function to set up and return a logger.

    Args:
        logger_name: Name of the logger
        log_level: Logging level (default: INFO)
        logstash_host: Logstash host (default: from env or 'logstash')
        logstash_port: Logstash port (default: from env or 5044)

    Returns:
        Configured logger instance

    Example:
        >>> from logging_config import setup_logger
        >>> logger = setup_logger()
        >>> logger.info("Application started")
    """
    config = LoggerConfig(logger_name, log_level, logstash_host, logstash_port)
    return config.get_logger()
