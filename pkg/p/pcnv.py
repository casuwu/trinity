import pandas as pd
from io import StringIO

def csv_to_string(file_path):
    with open(file_path, 'r') as file:
        data = file.read()
    return data

def convert_scientific_to_numeric(df, column):
    # Identify the numeric columns
    numeric_columns = df.select_dtypes(include=['float64', 'float32', 'int64', 'int32']).columns

    # Check if the specified column is numeric
    if column not in numeric_columns:
        raise ValueError(f"Column '{column}' is not numeric.")

    # Convert scientific notation to numeric
    df[column] = df[column].apply(lambda x: f'{x:.0f}' if pd.notnull(x) else x)

    return df

csv_string = csv_to_string('./holders.csv')

# convert string to csv file like object
data = StringIO(csv_string)

# read the data using pandas
df = pd.read_csv(data)

# convert dataframe to json
json = df.to_json(orient='records')
# Iterate over each element in the "Owed" column and convert the values
df = convert_scientific_to_numeric(df, 'Owed')

# Display the modified DataFrame
print(df)





