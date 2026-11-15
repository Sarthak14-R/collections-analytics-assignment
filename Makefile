# One command rebuilds everything from the raw CSVs in data/raw/
all: pipeline notebook dashboard
pipeline:
	python src/run_pipeline.py
notebook:
	python src/build_notebook.py
	cd notebooks && jupyter nbconvert --to notebook --execute --inplace analysis.ipynb
dashboard:
	python src/build_dashboard.py
