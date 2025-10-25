# 1. Use an official lightweight Python image as the base
FROM python:3.10-slim

# 2. Set the working directory inside the container
WORKDIR /app

# 3. Copy just the requirements file first
# This takes advantage of Docker's layer caching.
# This step will only re-run if requirements.txt changes.
COPY requirements.txt .

# 4. Install the Python dependencies
# --no-cache-dir: Disables the pip cache, resulting in a smaller image.
# -r: Specifies the requirements file.
RUN pip install --no-cache-dir -r requirements.txt

# 5. Copy the rest of your application code into the container
# This includes your app.py
COPY . .

# 6. Expose the port your app runs on
# This tells Docker the container will listen on port 8000
EXPOSE 8000

# 7. Define the command to run your application
# This runs Uvicorn, binds it to all IPs (0.0.0.0), and matches the EXPOSE port.
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]