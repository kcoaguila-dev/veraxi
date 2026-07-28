def list_skills() -> list[dict]:
    """
    Returns a list of available skills for the agent.
    This serves as a mock implementation for the skills backend.
    """
    return [
        {
            "name": "a11y-debugging",
            "description": "Accessibility debugging and auditing.",
        },
        {
            "name": "chrome-devtools",
            "description": "Browser debugging and DOM interaction.",
        },
        {
            "name": "flutter-add-widget-test",
            "description": "Implement component-level Flutter tests.",
        },
        {
            "name": "troubleshooting",
            "description": "Troubleshoot target issues and logs.",
        },
    ]
