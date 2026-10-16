def main():
    for s in ['abc', 'abc1', '123', '١٢٣', ' \t\n', '', 'a b', 'é']:
        print(s.isalnum(), s.isalpha(), s.isdigit(), s.isspace())
main()
