# Use an official Python runtime as a parent image
FROM python:3.9-slim

# Set the working directory in the container
WORKDIR /app

# Copy the dependencies file to the working directory
COPY requirements.txt .

# Install any needed packages specified in requirements.txt
# --no-cache-dir reduces the image size
RUN pip install --no-cache-dir -r requirements.txt

# Copy the content of the current directory to the working directory in the container
COPY . .

# Make port 8000 available to the world outside this container
EXPOSE 8000

# Run processor.py when the container launches
CMD ["python", "processor.py"]
