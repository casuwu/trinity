import pandas as pd
from io import StringIO

def csv_to_string(file_path):
    with open(file_path, 'r') as file:
        data = file.read()
    return data

csv_string = csv_to_string('./holders.csv')

# convert string to csv file like object
data = StringIO(csv_string)

# read the data using pandas
df = pd.read_csv(data)

# convert dataframe to json
json = df.to_json(orient='records')

print(json)