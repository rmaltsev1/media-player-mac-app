class LoginRequiredError(Exception):
	def __init__(self): super().__init__("Login is required to access this page.")

class LoginFailed(Exception):
	def __init__(self, msg): super().__init__(msg)

class FetchFailed(Exception):
	# VENDOR PATCH (ours): accept an optional message for clearer diagnostics.
	def __init__(self, msg="Failed to fetch stream!"): super().__init__(msg)

class CaptchaError(Exception):
	def __init__(self): super().__init__("Failed to bypass captcha!")

class HTTP(Exception):
	def __init__(self, code, message=""): super().__init__(f"{code}: {message}")
